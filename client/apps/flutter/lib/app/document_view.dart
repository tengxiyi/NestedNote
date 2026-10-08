// SPDX-License-Identifier: AGPL-3.0-or-later
//! 块文档的渲染（R1 富显示）。
//!
//! ## 只读
//!
//! 本组件把 [UiBlock] 列表渲染成真正的可视组件。它是**阅读视图**：
//! 编辑仍走纯文本编辑器（设计依据 `docs/design/09-编辑器技术方案.md`
//! 的两层拆分——先显示后编辑）。
//!
//! ## 附件与图片
//!
//! 附件内容存在内容寻址存储里，按 id 读取。图片直接渲染字节
//! （按 id 缓存，同一次会话不重复读盘）；文件渲染为卡片，
//! 点按打开附件面板（那里有"另存为"，内核读取时校验哈希）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/blocks.dart';
import '../core/attachment_providers.dart' as attachments;
import 'attachments_dialog.dart';
import 'typography.dart';

/// 按会话缓存的图片字节（内容寻址：同一 id 内容不变，缓存永不过期）。
final Map<String, Uint8List> _imageCache = <String, Uint8List>{};

/// 渲染一篇笔记的块序列。
class DocumentView extends ConsumerWidget {
  /// 构造。
  const DocumentView({required this.blocks, required this.noteId, super.key});

  final List<UiBlock> blocks;

  /// 所属笔记（附件面板按它列出附件）。
  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (blocks.isEmpty) {
      return Center(
        child: Text(
          '这篇笔记还没有内容。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final UiBlock block in blocks) _block(context, ref, block),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _block(BuildContext context, WidgetRef ref, UiBlock block) {
    final ThemeData theme = Theme.of(context);
    return switch (block) {
      ParagraphBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SelectableText(block.text, style: theme.textTheme.bodyLarge),
      ),
      HeadingBlock() => Padding(
        padding: EdgeInsets.only(top: block.level <= 2 ? 14 : 8, bottom: 4),
        child: SelectableText(
          block.text,
          style: _headingStyle(theme, block.level),
        ),
      ),
      ListBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < block.items.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 26,
                      child: Text(
                        block.ordered ? '${block.start + i}.' : '•',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        block.items[i],
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      ChecklistBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: <Widget>[
            Icon(
              block.checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: block.checked
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                block.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  decoration: block.checked ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
      QuoteBlock() => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(width: 3, color: theme.colorScheme.outline),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (block.text.isNotEmpty)
              SelectableText(
                block.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (block.cite != null)
              Text('—— ${block.cite}', style: theme.textTheme.labelSmall),
          ],
        ),
      ),
      CodeBlock() => Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (block.language != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  block.language!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            SelectableText(
              block.code,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'Consolas',
                fontFamilyFallback: <String>['Courier New', 'monospace'],
              ),
            ),
          ],
        ),
      ),
      DividerBlock() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(),
      ),
      ImageBlock() => _PreviewImage(
        attachmentId: block.attachmentId,
        alt: block.alt,
      ),
      FileBlock() => _FileCard(block: block, noteId: noteId),
      TableBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Table(
          border: TableBorder.all(color: theme.colorScheme.outlineVariant),
          children: <TableRow>[
            for (final UiTableRow row in block.rows)
              TableRow(
                decoration: row.header
                    ? BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                      )
                    : null,
                children: <Widget>[
                  for (final String cell in row.cells)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: SelectableText(
                        cell,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: row.header ? kEmphasisWeight : null,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      LinkBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          onTap: () async {
            // 不引 url_launcher（见 09 方案 §2.4）：外链打开需要
            // 确认策略，先提供"复制"，不静默跳转
            await Clipboard.setData(ClipboardData(text: block.href));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('链接已复制：${block.href}')));
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                block.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
              Text(
                block.href,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
      UnknownBlock() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '（有一段内容暂时渲染不出来：${block.kind}。它仍完整保存在笔记里。）',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    };
  }

  TextStyle? _headingStyle(ThemeData theme, int level) {
    final TextTheme textTheme = theme.textTheme;
    return switch (level) {
      1 => textTheme.headlineSmall?.copyWith(fontWeight: kEmphasisWeight),
      2 => textTheme.titleLarge?.copyWith(fontWeight: kEmphasisWeight),
      3 => textTheme.titleMedium?.copyWith(fontWeight: kEmphasisWeight),
      4 => textTheme.titleSmall?.copyWith(fontWeight: kEmphasisWeight),
      _ => textTheme.bodyLarge?.copyWith(
        fontWeight: kEmphasisWeight,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    };
  }
}

class _PreviewImage extends StatefulWidget {
  const _PreviewImage({required this.attachmentId, this.alt});

  final String attachmentId;
  final String? alt;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  Uint8List? _bytes;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Uint8List? cached = _imageCache[widget.attachmentId];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    try {
      final Uint8List bytes = await attachments.readAttachmentBytes(
        widget.attachmentId,
      );
      _imageCache[widget.attachmentId] = bytes;
      if (!mounted) {
        return;
      }
      setState(() => _bytes = bytes);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_bytes != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Image.memory(
              _bytes!,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            _error == null
                ? Icons.hourglass_empty
                : Icons.broken_image_outlined,
            size: 18,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error == null
                  ? (widget.alt ?? '图片加载中…')
                  : '图片读取失败（${widget.alt ?? '无替代文本'}）',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileCard extends ConsumerWidget {
  const _FileCard({required this.block, required this.noteId});

  final FileBlock block;
  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
          title: Text(
            block.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          subtitle: Text(
            '附件 · 点按查看与另存',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          onTap: () => showAttachmentsDialog(context, ref, noteId: noteId),
        ),
      ),
    );
  }
}
