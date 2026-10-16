// SPDX-License-Identifier: AGPL-3.0-or-later
//! super_editor Spike（R2 选型验证 A2，ADR 0002 §7）。
//!
//! ## 与 appflowy Spike 相同的桥接思路
//!
//! 我们的文本投影是 Markdown 风格，super_editor_markdown 提供
//! `deserializeMarkdownToDocument` / `serializeDocumentToMarkdown`——
//! 双向转换零自研映射。验证点：
//!
//! 1. **能否在 Flutter 3.47.6 上编译**（A1 就死在这）——本文件能通过
//!    analyze/test 即为通过；
//! 2. 我们的标记样张 → 文档节点类型（标题/任务/引用/代码/分隔线）；
//! 3. 渲染 + 编辑后序列化 → 既有 notes_save 路径。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_editor/super_editor.dart';

import '../core/note_providers.dart';

/// super_editor 实验视图（A2 Spike）。
class SuperEditorSpikeView extends ConsumerStatefulWidget {
  /// 构造。
  const SuperEditorSpikeView({required this.noteId, super.key});

  final String noteId;

  @override
  ConsumerState<SuperEditorSpikeView> createState() =>
      _SuperEditorSpikeViewState();
}

class _SuperEditorSpikeViewState extends ConsumerState<SuperEditorSpikeView> {
  Editor? _editor;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final String text = await ref.read(
        noteTextProvider(widget.noteId).future,
      );
      final MutableDocument document = deserializeMarkdownToDocument(text);
      if (!mounted) {
        return;
      }
      setState(() {
        _editor = Editor(
          editables: <String, Editable>{
            Editor.documentKey: document,
            Editor.composerKey: MutableDocumentComposer(),
          },
          isHistoryEnabled: true,
        );
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Editor? editor = _editor;
    if (_error != null) {
      return Center(
        child: Text(
          '实验编辑器加载失败：$_error',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    if (editor == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          width: double.infinity,
          color: theme.colorScheme.tertiaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: <Widget>[
              Text(
                '实验性 super_editor（A2 Spike）',
                style: theme.textTheme.labelSmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: () => unawaited(_save()),
                child: const Text('保存到内核'),
              ),
            ],
          ),
        ),
        Expanded(child: SuperEditor(editor: editor)),
      ],
    );
  }

  /// 编辑结果 → Markdown → 既有保存路径。
  Future<void> _save() async {
    final Editor? editor = _editor;
    if (editor == null) {
      return;
    }
    final String markdown = serializeDocumentToMarkdown(editor.document);
    final NoteSnapshot snapshot = await ref.read(
      noteSnapshotProvider(widget.noteId).future,
    );
    await ref
        .read(noteActionsProvider)
        .save(widget.noteId, title: snapshot.title, text: markdown);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已按实验编辑器的内容保存（产生一条修订）。')));
    }
  }
}
