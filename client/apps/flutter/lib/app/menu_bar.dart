// SPDX-License-Identifier: AGPL-3.0-or-later
//! 应用菜单栏（M1）。
//!
//! ## 铁律 F5：不放"画好但点不动"的项
//!
//! 用户明确要求过不要假按钮。因此菜单里**只出现当前真能用的项**：
//! 没有实现的（导出、打印、搜索、同步、加密、导入）**整个不出现**，
//! 也不写"（开发中）"这类占位项——那与置灰的假按钮没有区别，
//! 用户点下去还是什么都得不到。
//!
//! 因此本阶段的「格式」「工具」两个菜单**暂时不出现**。
//! 一个不存在的菜单比一个空菜单诚实。
//!
//! ## 结构参照印象笔记，但不照搬
//!
//! 菜单项与印象笔记对齐（那是用户已有的肌肉记忆），但内容按我们的能力裁剪：
//!
//! - 不做"账户 / 共享 / 群聊 / 演示"——我们没有账户与协作
//! - 不做"新建本地笔记本"——本地优先下**全部**笔记本都是本地的
//! - 不做"彻底删除"——那只能在回收站里发生，防误触（用户已确认）
//!
//! 完整取舍见 `docs/design/20-菜单栏与功能补齐规划.md`，改这里前先读那里。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/layout_providers.dart';
import '../core/notebook_providers.dart';
import '../core/note_providers.dart';
import 'about_dialog.dart';
import 'dialogs.dart';
import 'shortcuts_dialog.dart';
import 'icons.dart';
import 'shortcuts.dart';

/// 顶部菜单栏。
///
/// 放在 `AppBar` 之下、三栏之上（用户已确认的形态）：这样它是**跨三栏**的。
class AppMenuBar extends ConsumerWidget {
  /// 构造。
  const AppMenuBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuBar(
      children: <Widget>[
        _fileMenu(context, ref),
        _editMenu(context, ref),
        _viewMenu(context, ref),
        _helpMenu(context, ref),
      ],
    );
  }

  // ------------------------------------------------------------------ 文件

  Widget _fileMenu(BuildContext context, WidgetRef ref) {
    final String? notebookId = ref.watch(selectedNotebookIdProvider);
    return SubmenuButton(
      menuChildren: <Widget>[
        MenuItemButton(
          shortcut: AppShortcuts.newNote.activator,
          leadingIcon: const Icon(kNewNoteIcon, size: 18),
          // 在**当前选中的目录**里新建。内核可能把它下潜到最底层子目录
          //（见 `resolve_note_notebook`），因此这里传的是"用户点在哪"。
          onPressed: () => _createNote(context, ref, notebookId),
          child: const Text('新建笔记'),
        ),
        MenuItemButton(
          shortcut: AppShortcuts.newChildNotebook.activator,
          leadingIcon: const Icon(kNewNotebookIcon, size: 18),
          onPressed: () => _createNotebook(context, ref, notebookId),
          child: Text(notebookId == null ? '新建笔记本' : '在此新建子笔记本'),
        ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout, size: 18),
          onPressed: () => _quit(),
          child: const Text('退出'),
        ),
      ],
      child: const Text('文件'),
    );
  }

  // ------------------------------------------------------------------ 编辑

  Widget _editMenu(BuildContext context, WidgetRef ref) {
    // ## 为什么这几项不自己实现
    //
    // Flutter 的文本编辑通过 `Intent` 派发到**当前有焦点的**可编辑控件。
    // 菜单项若绕过这套机制直接改 `TextEditingController`，就会出现
    // "在菜单里按撤销，改掉的却是另一个输入框"这类错误。
    //
    // 因此统一派发标准 Intent，让焦点决定作用于谁。
    return SubmenuButton(
      menuChildren: <Widget>[
        MenuItemButton(
          shortcut: AppShortcuts.undo.activator,
          leadingIcon: const Icon(Icons.undo, size: 18),
          onPressed: () => _dispatch(
            context,
            const UndoTextIntent(SelectionChangedCause.toolbar),
          ),
          child: const Text('撤销'),
        ),
        MenuItemButton(
          shortcut: AppShortcuts.redo.activator,
          leadingIcon: const Icon(Icons.redo, size: 18),
          onPressed: () => _dispatch(
            context,
            const RedoTextIntent(SelectionChangedCause.toolbar),
          ),
          child: const Text('重做'),
        ),
        const Divider(),
        // 剪切/复制/粘贴**刻意不放在这里**：
        //
        // 它们在文本框里是系统级既有行为（右键菜单与 Ctrl+X/C/V 都能用），
        // 而菜单栏版需要额外处理"没有选中内容时该项应当不可用"，
        // 且无法可靠判断当前焦点在哪个输入框。
        //
        // 放一个"点了没反应"的剪切项，比不放更糟。
        // 这一条与"不放假按钮"是同一条原则的延伸。
        MenuItemButton(
          shortcut: AppShortcuts.selectAllInEditor.activator,
          leadingIcon: const Icon(Icons.select_all, size: 18),
          onPressed: () => _dispatch(
            context,
            const SelectAllTextIntent(SelectionChangedCause.toolbar),
          ),
          child: const Text('全选正文'),
        ),
      ],
      child: const Text('编辑'),
    );
  }

  // ------------------------------------------------------------------ 查看

  Widget _viewMenu(BuildContext context, WidgetRef ref) {
    final PaneLayout layout = ref.watch(paneLayoutProvider);
    final bool sidebarCollapsed = ref.watch(sidebarCollapsedProvider);

    return SubmenuButton(
      menuChildren: <Widget>[
        // 勾选态用 `CheckboxMenuButton` 表达，而不是在文字前后加"✓"——
        // 前者有正确的语义（屏幕阅读器能读出来、键盘能切换），
        // 后者只是一个字符，看起来像但用不了。
        CheckboxMenuButton(
          value: !sidebarCollapsed,
          onChanged: (bool? on) =>
              ref.read(sidebarCollapsedProvider.notifier).set(!(on ?? true)),
          child: const Text('笔记本栏'),
        ),
        CheckboxMenuButton(
          value: layout != PaneLayout.editorOnly,
          onChanged: (bool? on) => ref
              .read(paneLayoutProvider.notifier)
              .set(on ?? true ? PaneLayout.threePanes : PaneLayout.editorOnly),
          child: const Text('笔记列表'),
        ),
        CheckboxMenuButton(
          value: layout != PaneLayout.listOnly,
          onChanged: (bool? on) => ref
              .read(paneLayoutProvider.notifier)
              .set(on ?? true ? PaneLayout.threePanes : PaneLayout.listOnly),
          child: const Text('编辑器'),
        ),
        const Divider(),
        MenuItemButton(
          shortcut: AppShortcuts.viewListOnly.activator,
          onPressed: () => ref.read(paneLayoutProvider.notifier).listOnly(),
          child: const Text('只看笔记列表'),
        ),
        MenuItemButton(
          shortcut: AppShortcuts.viewEditorOnly.activator,
          onPressed: () => ref.read(paneLayoutProvider.notifier).editorOnly(),
          child: const Text('只看编辑器'),
        ),
        MenuItemButton(
          shortcut: AppShortcuts.viewThreePanes.activator,
          onPressed: () => ref.read(paneLayoutProvider.notifier).threePanes(),
          child: const Text('恢复三栏'),
        ),
      ],
      child: const Text('查看'),
    );
  }

  // ------------------------------------------------------------------ 帮助

  Widget _helpMenu(BuildContext context, WidgetRef ref) {
    return SubmenuButton(
      menuChildren: <Widget>[
        MenuItemButton(
          shortcut: AppShortcuts.shortcutsHelp.activator,
          leadingIcon: const Icon(Icons.keyboard_outlined, size: 18),
          onPressed: () => showShortcutsDialog(context),
          child: const Text('快捷键'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.info_outline, size: 18),
          onPressed: () => showNestedAboutDialog(context),
          child: const Text('关于拾光笔记'),
        ),
      ],
      child: const Text('帮助'),
    );
  }

  // ------------------------------------------------------------------ 动作

  void _dispatch(BuildContext context, Intent intent) {
    Actions.invoke(context, intent);
  }

  Future<void> _createNote(
    BuildContext context,
    WidgetRef ref,
    String? notebookId,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final CreatedNote created = await ref
          .read(noteActionsProvider)
          .create(notebookId: notebookId);
      // 新建后左栏跟到**实际落地**的目录（内核会下潜到最底层子目录）
      final String? landed = created.notebookId;
      if (landed != null && landed != notebookId) {
        ref.read(selectedNotebookIdProvider.notifier).select(landed);
      }
      messenger.showSnackBar(const SnackBar(content: Text('已新建笔记。')));
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _createNotebook(
    BuildContext context,
    WidgetRef ref,
    String? parentId,
  ) async {
    final String? name = await promptText(
      context,
      title: parentId == null ? '新建笔记本' : '新建子笔记本',
      hint: '例如：工作',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(notebookActionsProvider)
          .create(name: name.trim(), parentId: parentId);
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  /// 退出应用。
  ///
  /// ## 为什么不直接 `exit(0)`
  ///
  /// 编辑器在 `dispose()` 里会**补一次保存**（用户在去抖窗口内切走时
  /// 靠它保住最后几个字）。直接 `exit` 会跳过 dispose，那一次保存
  /// 就没机会发生——用户的最后一句输入丢了。
  ///
  /// `SystemNavigator.pop` 走正常的窗口关闭流程，dispose 会照常执行。
  void _quit() {
    SystemNavigator.pop();
  }
}
