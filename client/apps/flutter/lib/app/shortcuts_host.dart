// SPDX-License-Identifier: AGPL-3.0-or-later
//! 快捷键宿主：把 [AppShortcuts] 里的键绑到实际动作上。
//!
//! ## 为什么它必须在 `MaterialApp` **外面**
//!
//! 这是本项目踩到的一个真实缺陷，测试抓出来的：
//!
//! Flutter 的 `MaterialApp` 内部有一层 `DefaultTextEditingShortcuts`，
//! 专门接管文本框按键（`Ctrl+A/C/V/Z` 等）。按键事件从**焦点**开始，
//! 沿元素树**向上**冒泡，遇到第一个能处理它的 `Shortcuts` 就停下。
//!
//! 因此如果我们的 `Shortcuts` 放在 `MaterialApp` **里面**（例如页面里），
//! 它比 `DefaultTextEditingShortcuts` **更远离焦点**——按键先被后者吃掉，
//! 我们的绑定永远收不到。
//!
//! 症状是：**光标在正文里时 `Ctrl+1/2/3` 没反应，点一下空白处又能用了**。
//! 用户不会去分析按键派发顺序，他只会说"快捷键有时灵有时不灵"。
//!
//! 放到 `MaterialApp` 外面就解决了：在元素树里它比
//! `DefaultTextEditingShortcuts` 更靠上，冒泡时**先**命中我们。
//!
//! ## 相关：为什么不与 `AppShortcuts` 合并
//!
//! `shortcuts.dart` 只描述**键与标注**（纯数据，可在测试里当常量用）；
//! 本文件负责**绑定到动作**（依赖 Riverpod 与 BuildContext）。
//! 分开让"键表"可以被菜单、快捷键一览对话框、测试三处共用，
//! 而这三处都不需要 BuildContext。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/layout_providers.dart';
import 'shortcuts.dart';
import 'shortcuts_dialog.dart';

/// 把快捷键绑到动作上，并承载整个应用。
///
/// 见文件头"为什么必须在 `MaterialApp` 外面"。
class AppShortcutHost extends ConsumerWidget {
  /// 构造。
  const AppShortcutHost({required this.child, super.key});

  /// 被包裹的应用。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        AppShortcuts.toggleSidebar.activator: const ToggleSidebarIntent(),
        AppShortcuts.viewListOnly.activator: const SetLayoutIntent(
          PaneLayout.listOnly,
        ),
        AppShortcuts.viewEditorOnly.activator: const SetLayoutIntent(
          PaneLayout.editorOnly,
        ),
        AppShortcuts.viewThreePanes.activator: const SetLayoutIntent(
          PaneLayout.threePanes,
        ),
        AppShortcuts.zoomIn.activator: const ZoomIntent(ZoomDirection.increase),
        AppShortcuts.zoomOut.activator: const ZoomIntent(
          ZoomDirection.decrease,
        ),
        AppShortcuts.zoomReset.activator: const ZoomIntent(ZoomDirection.reset),
        AppShortcuts.shortcutsHelp.activator: const ShowShortcutsIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ToggleSidebarIntent: CallbackAction<ToggleSidebarIntent>(
            onInvoke: (_) {
              ref.read(sidebarCollapsedProvider.notifier).toggle();
              return null;
            },
          ),
          SetLayoutIntent: CallbackAction<SetLayoutIntent>(
            onInvoke: (SetLayoutIntent intent) {
              ref.read(paneLayoutProvider.notifier).set(intent.layout);
              return null;
            },
          ),
          ZoomIntent: CallbackAction<ZoomIntent>(
            onInvoke: (ZoomIntent intent) {
              final EditorFontScaleNotifier scale = ref.read(
                editorFontScaleProvider.notifier,
              );
              switch (intent.direction) {
                case ZoomDirection.increase:
                  scale.zoomIn();
                case ZoomDirection.decrease:
                  scale.zoomOut();
                case ZoomDirection.reset:
                  scale.reset();
              }
              return null;
            },
          ),
          ShowShortcutsIntent: CallbackAction<ShowShortcutsIntent>(
            onInvoke: (_) {
              showShortcutsDialog(context);
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

/// 折叠/展开笔记本栏。
class ToggleSidebarIntent extends Intent {
  /// 构造。
  const ToggleSidebarIntent();
}

/// 切换到某个显示模式。
class SetLayoutIntent extends Intent {
  /// 构造。
  const SetLayoutIntent(this.layout);

  /// 目标模式。
  final PaneLayout layout;
}

/// 打开快捷键一览。
class ShowShortcutsIntent extends Intent {
  /// 构造。
  const ShowShortcutsIntent();
}

/// 调整编辑器字号。
class ZoomIntent extends Intent {
  /// 构造。
  const ZoomIntent(this.direction);

  /// 调整方向。
  final ZoomDirection direction;
}

/// 字号调整的方向。
enum ZoomDirection {
  /// 放大。
  increase,

  /// 缩小。
  decrease,

  /// 恢复默认。
  reset,
}
