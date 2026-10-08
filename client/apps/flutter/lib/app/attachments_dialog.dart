// SPDX-License-Identifier: AGPL-3.0-or-later
//! 附件的界面侧：附加文件对话框、附件列表、另存为。
//!
//! ## 为什么"附加文件"要先把当前编辑保存
//!
//! 附加的动作发生在**内核侧**：它把块追加进文档并保存。如果编辑器里
//! 还有未保存的输入，内核保存的文档就会**覆盖**掉界面上的最新内容
//! ——用户的最后几个字丢了。因此流程必须是：先保存 → 再附加 →
//! 再重新加载正文（文档在内核侧变了，界面要跟上）。
//!
//! ## 为什么用系统文件对话框而不是自己造
//!
//! 选文件/选保存位置是操作系统的能力（用户对它的肌肉记忆、最近目录、
//! 权限），任何自绘实现都只会更差。`file_selector` 是 Flutter 官方
//! 的桌面文件对话框封装。

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/attachment_providers.dart' as attachments;

/// 选一个文件并附加到笔记，返回失败提示；取消或成功返回 `null`。
///
/// ## 为什么不接收 `BuildContext`
///
/// 选文件、附加、重载都是 `await`。若把 `BuildContext` 传进来再跨
/// 这些异步间隙使用，静态检查会正确地拦截。而本函数**不需要**界面
/// 能力：对话框是全局的，反馈由调用方（编辑器）用自己的
/// `mounted` + `context` 弹出。不收 context，这类问题就不存在。
Future<String?> pickAndAttachFile({
  required String noteId,
  required Future<void> Function() reloadNote,
}) async {
  const XTypeGroup group = XTypeGroup(label: '所有文件');
  final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
  if (file == null) {
    return null; // 用户取消，不算错误
  }
  final String? failure = await attachments.attachFileFromPath(
    noteId: noteId,
    sourcePath: file.path,
  );
  if (failure != null) {
    return failure;
  }
  await reloadNote();
  return null;
}

/// 显示一篇笔记的附件列表。
///
/// ## 为什么"读取失败"和"没有附件"要分开
///
/// `attachmentsList` 失败时返回空列表，FFI 层表达不了这个差别。
/// 若界面把空列表显示成"没有附件"，用户会以为附件丢了——
/// 那是本项目最忌讳的误报（数据没丢却吓用户）。因此这里先用
/// 一次只读探测区分两种情况：能正常读到"0 条"才显示"没有附件"。
Future<void> showAttachmentsDialog(
  BuildContext context,
  WidgetRef ref, {
  required String noteId,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => _AttachmentsDialog(noteId: noteId),
  );
}

class _AttachmentsDialog extends StatefulWidget {
  const _AttachmentsDialog({required this.noteId});

  final String noteId;

  @override
  State<_AttachmentsDialog> createState() => _AttachmentsDialogState();
}

class _AttachmentsDialogState extends State<_AttachmentsDialog> {
  List<attachments.AttachmentInfo>? _items;
  String? _error;
  String? _savingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<attachments.AttachmentInfo> items = await attachments
          .listAttachments(widget.noteId);
      if (!mounted) {
        return;
      }
      setState(() => _items = items);
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
    return AlertDialog(
      title: const Text('附件'),
      content: SizedBox(width: 460, child: _body(theme)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) {
      return Text(
        '附件列表读取失败：$_error\n\n这不代表附件丢了——只是这次没读出来。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final List<attachments.AttachmentInfo>? items = _items;
    if (items == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (items.isEmpty) {
      return const Text('这篇笔记还没有附件。');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final attachments.AttachmentInfo a in items)
          ListTile(
            dense: true,
            leading: Icon(
              a.mimeType.startsWith('image/')
                  ? Icons.image_outlined
                  : Icons.insert_drive_file_outlined,
              size: 20,
            ),
            title: Text(a.filename, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${_formatBytes(a.sizeBytes.toInt())} · ${a.mimeType}',
              style: theme.textTheme.labelSmall,
            ),
            // 另存为。哈希校验在内核读取时进行（铁律 D4）：
            // 文件损坏时这里会失败，而不是把坏文件存出去。
            trailing: _savingId == a.attachmentId
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: '另存为…',
                    icon: const Icon(Icons.save_alt, size: 18),
                    onPressed: () => _saveAs(a),
                  ),
          ),
      ],
    );
  }

  Future<void> _saveAs(attachments.AttachmentInfo info) async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: info.filename,
    );
    if (location == null || !mounted) {
      return;
    }
    final String path = location.path;
    setState(() => _savingId = info.attachmentId);
    try {
      final Uint8List bytes = await attachments.readAttachmentBytes(
        info.attachmentId,
      );
      await File(path).writeAsBytes(bytes, flush: true);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已保存到 $path')));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    } finally {
      if (mounted) {
        setState(() => _savingId = null);
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final double kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
