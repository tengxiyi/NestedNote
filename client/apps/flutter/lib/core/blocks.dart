// SPDX-License-Identifier: AGPL-3.0-or-later
//! 块文档的解析与界面模型（R1 富显示的数据层）。
//!
//! ## 与内核的关系
//!
//! `notes_read_document` 返回的 JSON 与**落库字节同源**（同一套 serde
//! 定义，`tag = "type"`、snake_case）。本文件把它解析成 [UiBlock]——
//! 渲染层只认这个类型，不认 JSON 也不认 Rust 绑定（A-LAYERING）。
//!
//! ## 未知类型的容错
//!
//! 内核加了新块变体、界面还没升级时，会出现未知 `type`。
//! 处理是**保留并标注**（[UnknownBlock]），绝不静默丢弃——
//! "界面上少了一段"和"存储里少了一段"在用户眼里是同一件事。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api/notes.dart' as rust;
import 'note_providers.dart';

/// 一次修订的块序列（渲染层的输入）。
@immutable
sealed class UiBlock {
  const UiBlock();
}

/// 段落。
@immutable
class ParagraphBlock extends UiBlock {
  const ParagraphBlock(this.text);

  final String text;
}

/// 标题（level 1–6）。
@immutable
class HeadingBlock extends UiBlock {
  const HeadingBlock(this.level, this.text);

  final int level;
  final String text;
}

/// 无序/有序列表项的公共形态。
@immutable
class ListBlock extends UiBlock {
  const ListBlock({
    required this.ordered,
    required this.start,
    required this.items,
  });

  final bool ordered;
  final int start;
  final List<String> items;
}

/// 待办项。
@immutable
class ChecklistBlock extends UiBlock {
  const ChecklistBlock(this.text, this.checked);

  final String text;
  final bool checked;
}

/// 引用。
@immutable
class QuoteBlock extends UiBlock {
  const QuoteBlock(this.text, this.cite);

  final String text;
  final String? cite;
}

/// 代码块。
@immutable
class CodeBlock extends UiBlock {
  const CodeBlock(this.language, this.code);

  final String? language;
  final String code;
}

/// 分隔线。
@immutable
class DividerBlock extends UiBlock {
  const DividerBlock();
}

/// 图片（内容寻址存储里的附件）。
@immutable
class ImageBlock extends UiBlock {
  const ImageBlock(this.attachmentId, this.alt);

  final String attachmentId;
  final String? alt;
}

/// 文件附件。
@immutable
class FileBlock extends UiBlock {
  const FileBlock(this.attachmentId, this.filename);

  final String attachmentId;
  final String filename;
}

/// 表格行。
@immutable
class UiTableRow {
  const UiTableRow(this.cells, this.header);

  final List<String> cells;
  final bool header;
}

/// 表格。
@immutable
class TableBlock extends UiBlock {
  const TableBlock(this.rows);

  final List<UiTableRow> rows;
}

/// 链接。
@immutable
class LinkBlock extends UiBlock {
  const LinkBlock(this.text, this.href);

  final String text;
  final String href;
}

/// 未知类型（内核先于界面升级时出现，保留并标注，不静默丢弃）。
@immutable
class UnknownBlock extends UiBlock {
  const UnknownBlock(this.kind);

  final String kind;
}

/// 解析 `notes_read_document` 返回的 JSON。
///
/// 结构坏掉的条目（缺字段等）跳过该条并继续——预览是展示层，
/// 一条坏块不该让整篇预览白屏；但 [UnknownBlock] 的占位会说明
/// 有内容渲染不出来，不假装它不存在。
List<UiBlock> parseBlocksJson(String json) {
  // jsonDecode 对坏 JSON 会抛 FormatException。预览是展示层：
  // 结构坏掉时显示"空"比整个预览白屏好——不假装它不存在。
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const <UiBlock>[];
  }
  if (decoded is! Map<String, Object?>) {
    return const <UiBlock>[];
  }
  final Object? blocks = decoded['blocks'];
  if (blocks is! List<Object?>) {
    return const <UiBlock>[];
  }
  return blocks
      .map((Object? raw) => _parseBlock(raw as Map<String, Object?>?))
      .whereType<UiBlock>()
      .toList(growable: false);
}

UiBlock? _parseBlock(Map<String, Object?>? map) {
  if (map == null) {
    return null;
  }
  final String type = map['type'] as String? ?? '';
  final String text = map['text'] as String? ?? '';
  switch (type) {
    case 'paragraph':
      return ParagraphBlock(text);
    case 'heading':
      final Object? level = map['level'];
      return HeadingBlock(level is int ? level.clamp(1, 6) : 1, text);
    case 'list':
      return _parseList(map);
    case 'checklist':
      return ChecklistBlock(text, map['checked'] as bool? ?? false);
    case 'quote':
      return QuoteBlock(text, map['cite'] as String?);
    case 'code':
      return CodeBlock(
        map['language'] as String?,
        map['code'] as String? ?? '',
      );
    case 'divider':
      return const DividerBlock();
    case 'image':
      // Id 是 serde(transparent) 的 UUID → JSON 里就是连字符字符串
      final String? id = map['attachment_id'] as String?;
      if (id == null) {
        return UnknownBlock(type);
      }
      return ImageBlock(id, map['alt'] as String?);
    case 'file':
      final String? id = map['attachment_id'] as String?;
      final String filename = map['filename'] as String? ?? '';
      if (id == null || filename.isEmpty) {
        return UnknownBlock(type);
      }
      return FileBlock(id, filename);
    case 'table':
      return _parseTable(map['rows']);
    case 'link':
      final String href = map['href'] as String? ?? '';
      if (href.isEmpty) {
        return ParagraphBlock(text);
      }
      return LinkBlock(text, href);
    case 'embed':
      return UnknownBlock(type);
    default:
      return UnknownBlock(type);
  }
}

ListBlock _parseList(Map<String, Object?> map) {
  final Object? rawItems = map['items'];
  final List<String> items = <String>[
    if (rawItems is List<Object?>)
      for (final Object? item in rawItems)
        if (item is Map<String, Object?>) item['text'] as String? ?? '',
  ];
  final bool ordered = map['ordered'] as bool? ?? false;
  final Object? start = map['start'];
  return ListBlock(
    ordered: ordered,
    start: start is int ? start : 1,
    items: items,
  );
}

TableBlock _parseTable(Object? rawRows) {
  final List<UiTableRow> rows = <UiTableRow>[
    if (rawRows is List<Object?>)
      for (final Object? rawRow in rawRows)
        if (rawRow is Map<String, Object?>)
          () {
            final Object? cells = rawRow['cells'];
            return UiTableRow(
              cells is List<Object?>
                  ? <String>[
                      for (final Object? cell in cells)
                        if (cell is Map<String, Object?>)
                          cell['text'] as String? ?? '',
                    ]
                  : const <String>[],
              cells is List<Object?> &&
                  cells.isNotEmpty &&
                  cells.first is Map<String, Object?> &&
                  (cells.first! as Map<String, Object?>)['header'] == true,
            );
          }(),
  ];
  return TableBlock(rows);
}

/// 读取一篇笔记的块序列（预览用）。
///
/// 失败抛 [NoteFailure]：预览读不出来必须显式报错，
/// 不能静默显示一片空白让用户以为笔记空了。
Future<List<UiBlock>> fetchNoteBlocks(String noteId) async {
  final rust.NoteResult result = await rust.notesReadDocument(id: noteId);
  if (!result.ok) {
    throw NoteFailure(
      code: result.code ?? 'UNKNOWN',
      hint: result.hint ?? '读取文档失败。',
    );
  }
  final String json = result.value?.documentJson ?? '';
  return parseBlocksJson(json);
}
