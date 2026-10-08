// SPDX-License-Identifier: AGPL-3.0-or-later
//! 导出与备份的数据层（包装 Rust 绑定，A-LAYERING）。

import '../src/rust/api/export.dart' as rust;

/// 导出一篇笔记为 Markdown。失败抛出可展示的提示文本。
Future<String> exportNoteMarkdown(String noteId) async =>
    rust.exportNoteMarkdown(id: noteId);

/// 导出一篇笔记为自包含 HTML。
Future<String> exportNoteHtml(String noteId) async =>
    rust.exportNoteHtml(id: noteId);

/// 导出整库为 JSON 备份（不含附件二进制内容）。
Future<String> exportDatabaseJson() async => rust.exportDatabaseJson();
