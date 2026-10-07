// SPDX-License-Identifier: AGPL-3.0-or-later
//! 标签编辑器。
//!
//! ## 为什么是"勾选 + 新建"一体的对话框
//!
//! 标签的常见操作是"给这篇笔记挑几个标签，顺便新建一个还没有的"。
//! 拆成两个对话框（先管理标签、再选标签）会让这件事变成四次点击加两次
//! 上下文切换。这里做成一个：上方是选择区，下方直接新建。
//!
//! ## 覆盖语义与"确定/取消"
//!
//! 对话框内部的勾选是**纯本地状态**，只在点「确定」时一次性写回
//! （整体覆盖）。这样：
//!
//! - 用户中途改主意可以「取消」，不会留下半套标签；
//! - 写回是**一次**操作，不是"每勾一个写一次"——后者在网络/磁盘慢时
//!   会看到列表反复跳动。
//!
//! ## 同名标签的"复活"会改变返回的 id
//!
//! 新建标签时，若同名标签在回收站里，内核会**复活原来那一行**并复用它的 id。
//! 因此这里始终用**返回值**里的 id 去勾选，而不是自己构造一个。
//! 否则勾上的会是一个库里不存在的 id，保存时外键直接失败。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/note_providers.dart';
import '../core/tag_providers.dart';
import 'icons.dart';

/// 打开标签编辑器；保存成功返回 `true`。
Future<bool> showTagEditor(
  BuildContext context, {
  required String noteId,
  required String noteTitle,
}) async {
  final bool? changed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _TagEditorDialog(noteId: noteId, noteTitle: noteTitle),
  );
  return changed ?? false;
}

class _TagEditorDialog extends ConsumerStatefulWidget {
  const _TagEditorDialog({required this.noteId, required this.noteTitle});

  final String noteId;
  final String noteTitle;

  @override
  ConsumerState<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends ConsumerState<_TagEditorDialog> {
  /// 当前勾选的标签 id。
  ///
  /// `null` 表示"还没从服务端数据初始化过"——不能直接用空集合当初始值，
  /// 否则数据到达时用户可能已经勾了几个，会被无声覆盖掉。
  Set<String>? _selected;

  /// 新建标签的输入框。
  final TextEditingController _newTag = TextEditingController();

  /// 是否正在保存（防重复提交）。
  bool _saving = false;

  @override
  void dispose() {
    _newTag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<TagEntry>> all = ref.watch(tagsProvider);
    final AsyncValue<List<TagEntry>> current = ref.watch(
      noteTagsProvider(widget.noteId),
    );
    final ThemeData theme = Theme.of(context);

    // 首次拿到已选标签时初始化本地状态。
    // 用 `??=` 而不是直接赋值：数据可能刷新多次，不该覆盖用户已做的改动。
    if (_selected == null && current.hasValue) {
      _selected = current.requireValue.map((TagEntry tag) => tag.id).toSet();
    }

    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Icon(kTagIcon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '标签 · ${widget.noteTitle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: switch (all) {
                AsyncLoading() => const Center(
                  child: CircularProgressIndicator(),
                ),
                AsyncError(:final Object error) => Center(
                  child: Text('$error', style: theme.textTheme.bodySmall),
                ),
                AsyncData(:final List<TagEntry> value) when value.isEmpty =>
                  Center(
                    child: Text(
                      '还没有标签。\n在下面输入一个名称即可新建。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                AsyncData(:final List<TagEntry> value) => ListView.builder(
                  itemCount: value.length,
                  itemBuilder: (BuildContext context, int index) {
                    final TagEntry tag = value[index];
                    final bool checked = _selected?.contains(tag.id) ?? false;
                    return CheckboxListTile(
                      dense: true,
                      value: checked,
                      title: Text(tag.name),
                      onChanged: (bool? next) => setState(() {
                        _selected ??= <String>{};
                        if (next ?? false) {
                          _selected!.add(tag.id);
                        } else {
                          _selected!.remove(tag.id);
                        }
                      }),
                    );
                  },
                ),
              },
            ),
            const Divider(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _newTag,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '新建标签',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (String value) => _createTag(value),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () => _createTag(_newTag.text),
                  child: const Text('新建'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '确定'),
        ),
      ],
    );
  }

  /// 新建标签并**立即勾上它**。
  Future<void> _createTag(String raw) async {
    final String name = raw.trim();
    if (name.isEmpty) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final TagEntry created = await ref.read(tagActionsProvider).create(name);
      if (!mounted) {
        return;
      }
      setState(() {
        // 用**返回值**的 id，而不是自己构造的——
        // 同名标签在回收站里时，内核会复活原行，id 与新建的不同。
        _selected ??= <String>{};
        _selected!.add(created.id);
        _newTag.clear();
      });
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      await ref
          .read(tagActionsProvider)
          .setForNote(widget.noteId, (_selected ?? <String>{}).toList());
      navigator.pop(true);
    } on NoteFailure catch (failure) {
      if (mounted) {
        setState(() => _saving = false);
      }
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }
}
