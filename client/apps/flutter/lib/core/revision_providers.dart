// SPDX-License-Identifier: AGPL-3.0-or-later
//! 修订历史与对比的**数据层**。
//!
//! ## 为什么单独一个文件，而不是写在界面的那个文件里
//!
//! 第一版把 provider 和被对比结果都写在 `lib/app/revision_history.dart` 里，
//! 结果被门禁 `A-LAYERING` 拦下——`lib/app/**` 不允许 import
//! `lib/src/rust/**`（铁律 A2 / F1：UI 只依赖 `lib/core/` 的提供者）。
//!
//! 这条约束是对的：界面不该知道"数据是跨语言的"这件事。
//! 拆开之后，界面只看到 [DiffResult] 这类纯 Dart 模型，
//! FFI 的存在被限制在本文件里。
//!
//! ## 关于错误处理
//!
//! 历史与对比**失败时抛出**，而不是返回空结果：
//! 空列表会让界面显示"还没有历史版本"，而真实原因可能是数据库出错。
//! 这个"失败伪装成没有数据"的坑，本项目在 `notebooks_tree` 上踩过一次
//! （见 `docs/03-踩坑备忘.md` §7.5）。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/notes.dart' as rust;
import 'note_providers.dart';

/// 从 core 层导出 FFI 的修订条目类型。
///
/// ## 为什么需要这一行（而不是让界面直接 import FFI）
///
/// 界面需要按 id 遍历修订列表，因此要写出 `List<RevisionEntry>` 这个类型。
/// 但门禁 `A-LAYERING` 禁止 `lib/app/**` 直接 import `lib/src/rust/**`
/// （铁律 A2 / F1）。
///
/// 在这里转出一个名字，界面就只依赖 `lib/core/`——
/// "数据来自跨语言调用"这件事被限制在数据层，界面看不到它。
/// 这正是那条分层规则想要的效果，而不是为了过门禁而绕。
typedef RevisionEntry = rust.RevisionEntry;

/// 一条修订（界面模型）。
class RevisionItem {
  /// 构造。
  const RevisionItem({
    required this.id,
    required this.version,
    required this.createdAtMs,
    required this.deviceId,
    required this.operation,
  });

  /// 修订标识。
  final String id;

  /// 版本号。
  final int version;

  /// 产生时间（UTC 毫秒）。
  final int createdAtMs;

  /// 产生该变更的设备。
  final String deviceId;

  /// 操作类型，如 `note.update`。
  final String operation;

  /// 从 FFI 结构转换。
  factory RevisionItem.fromRust(rust.RevisionEntry entry) => RevisionItem(
    id: entry.id,
    version: entry.version.toInt(),
    createdAtMs: entry.createdAtMs.toInt(),
    deviceId: entry.deviceId,
    operation: entry.operation,
  );
}

/// 差异中的一行（界面模型）。
class DiffLine {
  /// 构造。
  const DiffLine({required this.kind, required this.text});

  /// 类型：`unchanged` / `added` / `removed`。
  final String kind;

  /// 行内容。
  final String text;

  /// 是否为新增。
  bool get isAdded => kind == 'added';

  /// 是否为删除。
  bool get isRemoved => kind == 'removed';
}

/// 一次对比的结果。
///
/// ## 为什么是 sealed 而不是"带一个 missing 标志的结构"
///
/// 缺快照与"两版相同"是**两件不同的事**。做成两个变体之后，
/// 界面必须显式处理它们，编译器不允许把两者混为一谈。
/// 用 `missingSnapshot: bool` 的话，某个分支忘了判断就会显示空差异，
/// 而那会被读成"内容没变"——这是会误导用户的错误。
sealed class DiffResult {
  /// 构造。
  const DiffResult();
}

/// 成功比出差异。
class DiffContent extends DiffResult {
  /// 构造。
  const DiffContent({
    required this.oldVersion,
    required this.newVersion,
    required this.added,
    required this.removed,
    required this.lines,
  });

  /// 旧版本号。
  final int oldVersion;

  /// 新版本号。
  final int newVersion;

  /// 新增行数。
  final int added;

  /// 删除行数。
  final int removed;

  /// 逐行差异。
  final List<DiffLine> lines;

  /// 两版是否完全相同。
  bool get identical => added == 0 && removed == 0;
}

/// 因缺少内容快照而无法对比。
///
/// 迁移 `0003` 之前的修订只有元数据，没有内容。这时**不能**说"两版相同"，
/// 只能如实说"不知道"。
class DiffMissingSnapshot extends DiffResult {
  /// 构造。
  const DiffMissingSnapshot({
    required this.oldVersion,
    required this.newVersion,
    required this.oldMissing,
    required this.newMissing,
  });

  /// 旧版本号。
  final int oldVersion;

  /// 新版本号。
  final int newVersion;

  /// 旧版本是否缺快照。
  final bool oldMissing;

  /// 新版本是否缺快照。
  final bool newMissing;

  /// 供界面显示的一句话说明。
  ///
  /// 说清**是哪一侧缺**，并给出下一步——而不是笼统的"无法对比"：
  /// 用户看到"第 2 版没有内容快照"才知道该换个版本比。
  String get explanation {
    if (oldMissing && newMissing) {
      return '这两个版本都没有内容快照。\n\n'
          '内容快照是后来才加入的功能，此前的修订只记录了版本信息。';
    }
    if (oldMissing) {
      return '第 $oldVersion 版没有内容快照，无法与第 $newVersion 版对比。\n\n'
          '请选择更新的版本作为起点。';
    }
    return '第 $newVersion 版没有内容快照，无法对比。';
  }
}

/// 某篇笔记的修订历史（按版本倒序，最新在前）。
///
/// 失败时抛出而不是返回空列表（理由见文件头）。
///
/// ## 返回 FFI 生成的类型
///
/// 试过让它返回 `List<RevisionItem>`，但 Riverpod 3 对"family 返回自定义 class"
/// 的写法推断失败（`ref.watch` 拿到 `dynamic`）。返回 FFI 类型则正常，
/// 映射交给界面层。显式类型注解同样不写：Riverpod 3 未导出
/// `FutureProviderFamily`（与它不导出 `Override` 同理，本项目已多次踩到）。
final revisionHistoryProvider =
    FutureProvider.family<List<rust.RevisionEntry>, String>((
      Ref ref,
      String noteId,
    ) async {
      final rust.NoteResult result = await rust.notesRevisionHistory(
        id: noteId,
        limit: 0,
      );
      if (!result.ok) {
        throw NoteFailure(
          code: result.code ?? 'UNKNOWN',
          hint: result.hint ?? '读取修订历史失败。',
        );
      }
      return result.value?.revisions ?? const <rust.RevisionEntry>[];
    });

/// 两条修订之间的对比。
///
/// 键是 `(笔记 id, 旧修订 id, 新修订 id)`。
final revisionDiffProvider =
    FutureProvider.family<DiffResult, (String, String, String)>((
      Ref ref,
      (String, String, String) key,
    ) async {
      final (String noteId, String oldId, String newId) = key;
      final rust.NoteResult result = await rust.notesRevisionDiff(
        oldId: oldId,
        newId: newId,
      );
      if (!result.ok) {
        throw NoteFailure(
          code: result.code ?? 'UNKNOWN',
          hint: result.hint ?? '对比修订失败。',
        );
      }
      final rust.RevisionDiffPayload? payload = result.value?.diff;
      if (payload == null) {
        throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核未返回对比结果。');
      }
      if (payload.missingSnapshot) {
        return DiffMissingSnapshot(
          oldVersion: payload.older.version.toInt(),
          newVersion: payload.newer.version.toInt(),
          oldMissing: payload.oldMissing,
          newMissing: payload.newMissing,
        );
      }
      return DiffContent(
        oldVersion: payload.older.version.toInt(),
        newVersion: payload.newer.version.toInt(),
        added: payload.added.toInt(),
        removed: payload.removed.toInt(),
        lines: payload.lines
            .map(
              (rust.RevisionDiffEntry line) =>
                  DiffLine(kind: line.kind, text: line.text),
            )
            .toList(growable: false),
      );
    });

/// 读取一次修订的内容快照（已投影为纯文本），供"恢复到这一版"使用。
///
/// 返回 `null` 表示该修订**没有内容快照**（启用快照之前的修订）——
/// 此时不可恢复。`null` 与空字符串是两种状态：空字符串是"那一版
/// 本来就是空的"，可以恢复（结果是清空正文，这必须让用户在确认框里
/// 看见，而不是静默拒绝）；`null` 是"根本没有内容可恢复"。
///
/// 其它失败（数据库等）抛 [NoteFailure]。
Future<String?> fetchRevisionSnapshot(String revisionId) async {
  final rust.NoteResult result = await rust.notesRevisionSnapshot(
    revisionId: revisionId,
  );
  if (result.ok) {
    return result.value?.text ?? '';
  }
  if (result.code == 'SNAPSHOT_MISSING') {
    return null;
  }
  throw NoteFailure(
    code: result.code ?? 'UNKNOWN',
    hint: result.hint ?? '读取快照失败。',
  );
}
