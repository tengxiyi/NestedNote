// SPDX-License-Identifier: AGPL-3.0-or-later
//! 回收站维护 —— 保留期提示与启动时的到期清理。
//!
//! ## 这个模块存在的唯一原因
//!
//! 「删除」在界面上只做软删，但**超过保留期会被自动彻底删除**。
//! 这是全项目唯一不经用户操作就销毁数据的路径（铁律 T1 的显式例外，
//! 见 `docs/02-工程铁律.md` 的 T1 修订说明）。
//!
//! 因此它必须满足两个要求：
//!
//! 1. **可预期**：用户能看到"还剩几天"，而不是内容无声消失；
//! 2. **可告知**：清理发生时要说清删掉了什么，而不是悄悄删。
//!
//! ## 保留期从内核读，不在 Dart 侧写死
//!
//! 保留期定义在内核（`NestedCore::TRASH_RETENTION_DAYS`）。这里通过 FFI 读取。
//! 若在 Dart 侧再写一个 15，两处会漂移，出现"提示还剩 3 天、其实已经删了"
//! 这类最难解释的现象。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/notes.dart' as rust;
import 'engine_providers.dart';
import 'note_providers.dart';

/// 一天的毫秒数（用于把"删除时间"换算成"还剩几天"）。
const int kMsPerDay = 24 * 60 * 60 * 1000;

/// 回收站保留期（天），来自内核。
///
/// 内核对不可用的引擎返回 -1；此时用 0 表示"未知"，
/// 界面应当避免显示"还剩 0 天"这种会吓到人的文案。
final FutureProvider<int> trashRetentionDaysProvider = FutureProvider<int>((
  Ref ref,
) async {
  await ref.watch(engineProvider.future);
  final int days = (await rust.trashRetentionDays()).toInt();
  return days < 0 ? 0 : days;
});

/// 一条已删笔记的"剩余天数"。
///
/// `remainingDays` 为 0 表示**已过期，下次启动会被清理**。
class TrashAge {
  /// 构造。
  const TrashAge({required this.remainingDays, required this.expired});

  /// 还剩多少天（0 表示已过期）。
  final int remainingDays;

  /// 是否已过期（下次启动清理时会被彻底删除）。
  final bool expired;
}

/// 计算某条已删内容还剩多少天。
///
/// ## 判定必须与内核**严格一致**，否则会出现"说删了却没删"
///
/// 内核的清理条件是 `deleted_at_ms < cutoff`（**严格小于**），也就是
/// "刚好满 15 天"那一刻还**不删**，要再过一毫秒。
///
/// 因此这里的过期判定也必须是 `remainingMs < 0` 而不是 `<= 0`。
/// 本项目第一版写成了 `<= 0`，结果在临界的那一天界面显示"已过期"，
/// 而内核并没有删——用户重启后发现内容还在，就会怀疑提示不准；
/// 更糟的是反向情况：提示"还剩 1 天"时其实已经被删。
///
/// **两处判定条件必须逐字对齐**，这是"倒计时可信"的唯一保证。
/// 对应的内核条件是 `repositories::notes::purge_deleted_before`。
TrashAge trashAgeOf({
  required int deletedAtMs,
  required int retentionDays,
  required int nowMs,
}) {
  if (retentionDays <= 0) {
    // 保留期未知（引擎未就绪）：不要给出会误导的倒计时
    return const TrashAge(remainingDays: 0, expired: false);
  }
  final int expiryMs = deletedAtMs + retentionDays * kMsPerDay;
  final int remainingMs = expiryMs - nowMs;

  if (remainingMs < 0) {
    // 严格超过保留期——与内核 `<` 的判定一致
    return const TrashAge(remainingDays: 0, expired: true);
  }
  if (remainingMs == 0) {
    // 临界点：内核此刻**还没删**。界面说"还剩 0 天"而不说过期，
    // 由界面文案把它呈现为"下次启动将清理"。
    return const TrashAge(remainingDays: 0, expired: false);
  }
  // 向上取整：还剩 1.2 天时说"还剩 2 天"更安全（不会让用户以为还有 1 天）
  final int days = (remainingMs + kMsPerDay - 1) ~/ kMsPerDay;
  return TrashAge(remainingDays: days, expired: false);
}

/// 一次启动清理的结果。
class TrashSweepResult {
  /// 构造。
  const TrashSweepResult({
    required this.notes,
    required this.notebooks,
    required this.expiredCount,
  });

  /// 被彻底删除的笔记数。
  final int notes;

  /// 被彻底删除的笔记本数。
  final int notebooks;

  /// 清理**之后**仍已到期的笔记数（清理失败时会 > 0）。
  final int expiredCount;

  /// 本次是否真的删掉了东西。
  bool get removedAnything => notes > 0 || notebooks > 0;
}

/// 回收站维护服务。
class TrashMaintenance {
  /// 构造。
  const TrashMaintenance(this._ref);

  final Ref _ref;

  /// 执行一次到期清理。
  ///
  /// ## 为什么要返回结果而不是默默删掉
  ///
  /// 这是唯一不经用户操作就销毁数据的路径。**悄悄删是错的**：
  /// 用户下次打开回收站发现东西少了，只会以为数据丢了。
  /// 调用方应当把结果告知用户（见 `TrashSweepNotice`）。
  ///
  /// ## 失败为什么不抛
  ///
  /// 清理是后台维护动作，不是用户操作。失败就下次启动再试，
  /// 绝不能因为它而阻断应用启动。内核侧同样返回 (0,0) 而不是报错。
  Future<TrashSweepResult> sweep() async {
    await _ref.read(engineProvider.future);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final (int notes, int notebooks) = await rust.trashPurge(nowMs: now);
    final int expired = (await rust.trashExpiredCount(nowMs: now)).toInt();
    if (notes > 0 || notebooks > 0) {
      // 清理确实动了数据 → 让列表与计数刷新，否则界面还显示已消失的内容
      _ref.invalidate(noteListProvider);
      _ref.invalidate(noteCountProvider);
    }
    return TrashSweepResult(
      notes: notes,
      notebooks: notebooks,
      expiredCount: expired < 0 ? 0 : expired,
    );
  }
}

/// 回收站维护入口。
final Provider<TrashMaintenance> trashMaintenanceProvider =
    Provider<TrashMaintenance>(TrashMaintenance.new);

/// 启动时执行一次到期清理，并把结果保留下来供界面提示。
///
/// 返回 `null` 表示本次没有删任何东西（**不该打扰用户**——
/// 什么都没删还弹一句提示是纯噪音，而且会让人以为出了事）。
final FutureProvider<TrashSweepResult?> startupTrashSweepProvider =
    FutureProvider<TrashSweepResult?>((Ref ref) async {
      final TrashSweepResult result = await ref
          .read(trashMaintenanceProvider)
          .sweep();
      return result.removedAnything ? result : null;
    });
