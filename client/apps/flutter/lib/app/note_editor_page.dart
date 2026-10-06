// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记编辑页。
//!
//! ## 为什么是"纯文本 + 块模型"两段式
//!
//! 内核存的是**块模型**（`nested-model`），而 P1 阶段还没有块级编辑器。
//! 因此这里先做一条诚实的降级通路：
//!
//! - **读**：块 → 纯文本（每个块一行），见 Rust 侧 `document_to_text`
//! - **写**：纯文本按换行切成段落块，见 Rust 侧 `text_to_document`
//!
//! 这条路径会**丢失**行内标记（加粗/链接）与块的种类（标题/列表/引用），
//! 因此它只是"能看见结果的通路"，不是最终形态。P3 的块编辑器会直接操作块模型。
//! 这个取舍写在这里而不是留给人猜：用户在这种编辑器里排版，格式不会被保留。
//!
//! ## 保存策略
//!
//! 手动保存 + 离开前提示。**没有**做自动保存：`save_note` 目前无条件递增修订号
//! 并写入同步队列（技术债 #11），自动保存会变成"每敲一个字产生一条修订"。
//! 等 #11 修好（内容无变化则不产生修订）之后再考虑自动保存。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/note_providers.dart';

/// 笔记编辑页。
class NoteEditorPage extends ConsumerStatefulWidget {
  /// 构造。
  const NoteEditorPage({required this.noteId, super.key});

  /// 要编辑的笔记标识。
  final String noteId;

  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  final TextEditingController _controller = TextEditingController();

  /// 已保存的内容，用于判断"是否有未保存改动"。
  String _savedText = '';

  /// 是否正在加载初始内容。
  bool _loading = true;

  /// 是否正在保存。
  bool _saving = false;

  /// 加载失败时的提示。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final String text = await ref.read(noteTextProvider(widget.noteId).future);
      if (!mounted) {
        return;
      }
      setState(() {
        _controller.text = text;
        _savedText = text;
        _loading = false;
      });
    } on NoteFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = failure.hint;
        _loading = false;
      });
    }
  }

  bool get _dirty => _controller.text != _savedText;

  Future<bool> _save() async {
    if (!_dirty || _saving) {
      return true;
    }
    setState(() => _saving = true);
    try {
      final String text = _controller.text;
      await ref.read(noteActionsProvider).save(widget.noteId, text);
      if (!mounted) {
        return true;
      }
      setState(() {
        _savedText = text;
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存')));
      return true;
    } on NoteFailure catch (failure) {
      if (!mounted) {
        return false;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure.hint)));
      return false;
    }
  }

  /// 离开前确认未保存的改动。
  Future<bool> _confirmLeave() async {
    if (!_dirty) {
      return true;
    }
    final NavigatorState navigator = Navigator.of(context);
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('还有未保存的改动'),
        content: const Text('离开将丢失这些改动。要先保存吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃改动'),
          ),
          FilledButton(
            onPressed: () async {
              // 先保存，再用**对话框自己的** context 关闭它。
              // 保存是异步的，await 之后再用 context 会被 analysis 拦下——
              // 因此把 Navigator 引用提前取好。
              final NavigatorState dialogNavigator = Navigator.of(dialogContext);
              final bool saved = await _save();
              dialogNavigator.pop(saved);
            },
            child: const Text('保存并离开'),
          ),
        ],
      ),
    );
    // 对话框返回后 Navigator 仍然有效（它是 State 级引用，不依赖 BuildContext）
    if (leave == true) {
      navigator.pop();
    }
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) {
          return;
        }
        // 不使用 context：_confirmLeave 内部已用 State 级的 Navigator 完成跳转
        await _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑笔记'),
          actions: <Widget>[
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                tooltip: '保存',
                onPressed: _dirty ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_loadError!, textAlign: TextAlign.center),
                ),
              )
            : Column(
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: theme.textTheme.bodyLarge,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '开始写点什么…\n\n（P1 编辑器为纯文本：每行会保存为一个段落块）',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                  if (_dirty)
                    Container(
                      width: double.infinity,
                      color: theme.colorScheme.secondaryContainer,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        '有未保存的改动',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
