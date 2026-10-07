// SPDX-License-Identifier: AGPL-3.0-or-later
//! 拾光笔记 / NestedNote —— Flutter 应用入口。
//!
//! 分层约定（《工程铁律》A1/A2/F1）：
//!
//! ```text
//! lib/app        应用启动、主题、路由
//! lib/core       引擎封装（**唯一**允许调用 Rust FFI 的位置）、平台适配、错误映射
//! lib/src/rust   flutter_rust_bridge 生成的绑定（不入库，仅 lib/core 可 import）
//! lib/features   业务页面（禁止直接接触 FFI）
//! lib/editor     编辑器与 Document Model Adapter
//! lib/search     搜索
//! lib/settings   设置
//! lib/sync       同步状态与冲突 UI
//! ```
//!
//! **禁止**在本层（或任何 Dart 代码）直接访问 SQLite、文件数据库或实现业务规则：
//! 所有事实来自 Rust 内核（铁律 T4）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/dialogs.dart';
import 'core/trash_providers.dart';
import 'core/ui_diagnostics.dart';

void main() {
  runApp(
    const ProviderScope(
      child: _Bootstrap(
        // 指针位置追踪要包在**最外层**：右键菜单需要知道光标在哪，
        // 而 Flutter 没有公开"查询当前鼠标位置"的接口。
        child: PointerPositionTracker(child: NestedNoteApp()),
      ),
    ),
  );
}

/// 应用启动引导：在渲染界面之前装好横切关注点。
///
/// 目前有两项：
///
/// 1. **界面状态诊断**（见 `core/ui_diagnostics.dart`）——
///    放在这里而不是某个页面，是因为诊断应当覆盖所有页面。
/// 2. **回收站到期清理**（见 `core/trash_providers.dart`）——
///    这是全项目唯一不经用户操作就销毁数据的动作，必须**只做一次**
///    且**结果要告知用户**。放在启动时而不是后台定时器里，
///    是因为"启动时"是唯一能保证"用户在电脑前"的时机：
///    在用户不知情时后台删数据是不可接受的。
///
/// 为什么不直接在 `main()` 里做：两者都需要 Riverpod 容器，
/// 而容器由 `ProviderScope` 提供——因此必须有一个
/// `ConsumerStatefulWidget` 位于 `ProviderScope` 之内才能拿到 `ref`。
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap({required this.child});

  final Widget child;

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  @override
  void initState() {
    super.initState();
    // read 一次即可：Provider 只创建一次实例，其内部订阅随之只装一次
    ref.read(uiDiagnosticsProvider);
    // 启动清理：放到下一帧触发，避免在 initState 里做异步工作
    WidgetsBinding.instance.addPostFrameCallback((_) => _sweepTrash());
  }

  /// 执行一次回收站到期清理，并把结果告知用户。
  ///
  /// ## 为什么必须告知
  ///
  /// 这是唯一"用户没操作、数据却消失了"的路径。悄悄删是错的：
  /// 用户下次打开回收站发现东西少了，只会以为数据丢了。
  Future<void> _sweepTrash() async {
    TrashSweepResult? result;
    try {
      result = await ref.read(startupTrashSweepProvider.future);
    } catch (_) {
      // 清理失败绝不能影响启动：它是后台维护动作，不是用户操作。
      // 内核侧同样返回 (0,0) 而不是报错，这里再兜一层。
      return;
    }
    if (!mounted || result == null) {
      // 本轮没删任何东西 → **不打扰用户**。
      // 什么都没删还弹提示是纯噪音，而且会让人以为出了事。
      return;
    }
    final List<String> parts = <String>[
      if (result.notes > 0) '${result.notes} 篇笔记',
      if (result.notebooks > 0) '${result.notebooks} 个笔记本',
    ];
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('回收站中超过保留期的 ${parts.join('、')}已被自动清理。'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
