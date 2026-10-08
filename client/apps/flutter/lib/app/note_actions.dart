// SPDX-License-Identifier: AGPL-3.0-or-later
//! 对**一篇笔记**的界面动作：复制一份、移动、编辑标签、删除、查修订历史。
//!
//! ## 为什么抽成独立文件
//!
//! 这些动作原先写在 `note_list_pane.dart` 的 State 里（私有方法），
//! 只有中栏右键菜单能用。而菜单栏的「笔记」菜单需要**同一批动作**。
//!
//! 有三条路：
//!
//! 1. 菜单持有中栏 State 的引用 —— 把"谁持有状态"与"谁用动作"绑死，
//!    很快会变成互相引用；
//! 2. 在菜单里**重写一遍** —— 同一条业务规则（例如"删除要二次确认、
//!    删完提示去回收站"）写两遍，改一处漏一处；
//! 3. **抽成函数**，两处都调 —— 本文件。
//!
//! 选了第三条。这些函数只依赖 `BuildContext` 与 `WidgetRef`，
//! 不需要知道调用方是右键菜单还是菜单栏。
//!
//! ## 每个动作都自己给反馈
//!
//! 成功/失败都由这里弹 SnackBar，调用方不必各写一遍——
//! 否则"右键删除有提示、菜单删除没提示"这种不一致迟早出现。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notebook_providers.dart';
import '../core/note_providers.dart';
import '../core/trash_providers.dart';
import 'note_list_pane.dart' show formatAbsoluteTime;
import 'notebook_sidebar.dart';
import 'revision_history.dart';
import 'tag_editor.dart';

/// 复制一份。
///
/// 复制后**不自动打开**副本：用户点"复制一份"通常是为了做点别的，
/// 立刻把右栏切走会打断他手上的事。改为提示一句并给「打开副本」按钮。
Future<void> duplicateNote(
  BuildContext context,
  WidgetRef ref,
  NoteItem note, {
  ValueChanged<String>? onOpen,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    final String newId = await ref.read(noteActionsProvider).duplicate(note.id);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已复制一份（标题带「（副本）」）。'),
        action: onOpen == null
            ? null
            : SnackBarAction(label: '打开副本', onPressed: () => onOpen(newId)),
      ),
    );
  } on NoteFailure catch (failure) {
    messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
  }
}

/// 移动到另一个笔记本。
Future<void> moveNote(
  BuildContext context,
  WidgetRef ref,
  NoteItem note,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final List<NotebookNode> tree =
      ref.read(notebooksTreeProvider).value ?? const <NotebookNode>[];
  final String? target = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => SimpleDialog(
      title: Text('移动「${note.title}」到…'),
      children: <Widget>[
        SimpleDialogOption(
          // 用空串表示"移出笔记本"；null 表示"用户取消"——
          // 两者必须区分，否则无法表达"移出"这个合法操作
          onPressed: () => Navigator.of(dialogContext).pop(''),
          child: const Text('（移出笔记本）'),
        ),
        for (final NotebookNode node in tree)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(node.id),
            child: Padding(
              // 与左栏用同一套缩进规则，避免两处的层级观感不一致
              padding: EdgeInsets.only(left: notebookIndent(node.depth)),
              child: Text(node.name, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    ),
  );
  if (target == null || !context.mounted) {
    return;
  }
  try {
    await ref
        .read(notebookActionsProvider)
        .moveNote(note.id, target.isEmpty ? null : target);
  } on NoteFailure catch (failure) {
    messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
  }
}

/// 编辑标签。
Future<void> editNoteTags(
  BuildContext context,
  WidgetRef ref,
  NoteItem note,
) async {
  await showTagEditor(context, noteId: note.id, noteTitle: note.title);
}

/// 查看修订历史。
Future<void> showNoteHistory(
  BuildContext context,
  WidgetRef ref,
  NoteItem note,
) async {
  await showRevisionHistory(context, noteId: note.id, noteTitle: note.title);
}

/// 移入回收站（软删除，铁律 T7）。
///
/// 删完提示"可在回收站中恢复（保留 N 天）"——删除是**不可逆流程的起点**，
/// 用户必须知道还能找回，以及还有多久。
Future<void> deleteNote(
  BuildContext context,
  WidgetRef ref,
  NoteItem note,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final int retention = ref.read(trashRetentionDaysProvider).value ?? 0;
  try {
    await ref.read(noteActionsProvider).delete(note.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          retention > 0
              ? '「${note.title}」已删除。可在回收站中恢复（保留 $retention 天）'
              : '「${note.title}」已删除。可在回收站中恢复。',
        ),
        action: SnackBarAction(
          label: '知道了',
          onPressed: () => messenger.hideCurrentSnackBar(),
        ),
      ),
    );
  } on NoteFailure catch (failure) {
    messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
  }
}

/// 显示属性。
Future<void> showNoteProperties(
  BuildContext context,
  WidgetRef ref,
  NoteItem note,
) async {
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(note.title.isEmpty ? '（无标题笔记）' : note.title),
      content: SizedBox(
        width: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _propertyRow('标识', note.id),
            _propertyRow('修订号', '第 ${note.version} 版'),
            _propertyRow('最后修改', formatAbsoluteTime(note.updatedAtMs)),
            if (note.deletedAtMs != null)
              _propertyRow('删除时间', formatAbsoluteTime(note.deletedAtMs!)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 属性对话框里的一行。
Widget _propertyRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(
        width: 72,
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
      Expanded(child: SelectableText(value)),
    ],
  ),
);
