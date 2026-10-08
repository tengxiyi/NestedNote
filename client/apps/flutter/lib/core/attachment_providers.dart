// SPDX-License-Identifier: AGPL-3.0-or-later
//! 附件的数据层：包装 Rust 绑定，供界面层使用。
//!
//! ## 为什么这个文件必须存在
//!
//! 铁律 A-LAYERING：`lib/app/**`（界面）不得直接 import Rust 生成绑定，
//! 必须经过 `lib/core/**`（数据层）。第一版附件对话框直接
//! `import '../src/rust/api/attachments.dart'`，被规则检查器当场拦下
//! ——这正是这层检查存在的意义：它保证"换内核实现时界面不用动"
//! 的承诺在结构上成立，而不只是口头约定。
//!
//! 本文件只做转发：参数与返回类型保持与绑定一致，不加业务规则——
//! 规则都在内核里（铁律 T4），这里加规则只会造成两份事实。
//! 文件对话框（选路径）是界面能力，留在 app 层；这里只接收**路径**。

import 'dart:typed_data';

import '../src/rust/api/attachments.dart' as rust;

export '../src/rust/api/attachments.dart' show AttachmentInfo;

/// 把一个文件附加到笔记，返回失败提示；成功返回 `null`。
///
/// 内核完成全部三步：复制进内容寻址存储、登记元数据、把块写进文档。
/// **调用方随后必须重新加载正文**——文档在内核侧变了。
Future<String?> attachFileFromPath({
  required String noteId,
  required String sourcePath,
}) async {
  final rust.AttachmentInfo info = await rust.attachmentsAttach(
    noteId: noteId,
    sourcePath: sourcePath,
    atMs: DateTime.now().millisecondsSinceEpoch,
  );
  if (!info.ok) {
    return info.hint ?? '附加失败。';
  }
  return null;
}

/// 列出一篇笔记的全部附件。
Future<List<rust.AttachmentInfo>> listAttachments(String noteId) =>
    rust.attachmentsList(noteId: noteId);

/// 读出一个附件的完整内容（内核读取时校验哈希，铁律 D4）。
Future<Uint8List> readAttachmentBytes(String attachmentId) =>
    rust.attachmentsReadBytes(attachmentId: attachmentId);
