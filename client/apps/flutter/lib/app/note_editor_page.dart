// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记编辑面板 —— 三栏布局的**右栏**。
//!
//! ## R2 起：编辑面由 super_editor 提供
//!
//! [`NoteEditorPane`] 的实现在 `super_editor_pane.dart`
//! （super_editor 所见即所得 + 工具栏，ADR 0002 §8）；
//! 保存走既有 `save_note` 路径（修订/导出/活动日志全沿用）。
//! 「预览」按钮保留为 R1 只读渲染的迁移兜底。

import 'package:flutter/material.dart';

import 'super_editor_pane.dart';

export 'super_editor_pane.dart' show NoteEditorPane;

/// 笔记编辑页（整页形态）。
///
/// 用于需要独立路由的场景（例如将来从搜索结果直接打开）。
/// 主界面的右栏请用 [NoteEditorPane]。
class NoteEditorPage extends StatelessWidget {
  /// 构造。
  const NoteEditorPage({required this.noteId, super.key});

  /// 要编辑的笔记标识。
  final String noteId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑笔记')),
      body: NoteEditorPane(noteId: noteId),
    );
  }
}
