// SPDX-License-Identifier: AGPL-3.0-or-later
// 诊断：左栏目录树在回收站操作之后"不显示了"。
//
// 症状（用户报告）：在回收站里删掉几个目录后，左侧目录树变空，
// 并显示"请尝试重启应用；若问题持续，请从备份恢复数据"。
//
// 那句提示是 `CoreError::Database` 的通用兜底文案，因此**大概率是查询失败**，
// 而不是"确实没有目录"。这个脚本把真实的 ok/code/hint 打出来，
// 让"失败"与"为空"不再混在一起（踩坑备忘 §7.5 记的就是这类混淆）。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/diag_tree_after_trash.dart

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

Future<void> main() async {
  await RustLib.init();
  final status = await engineStart(dataDir: resolveAppDataDirForTools().path);
  stdout.writeln('引擎 ready=${status.ready}');
  stdout.writeln('');

  // 1) notebooksTree —— 左栏数据源
  final tree = await notebooksTree();
  stdout.writeln('=== notebooksTree ===');
  stdout.writeln('  ok=${tree.ok}  code=${tree.code}  hint=${tree.hint}');
  stdout.writeln('  debug=${tree.debugDetail}');
  stdout.writeln('  节点数=${tree.value?.notebooks.length ?? -1}');
  for (final n in tree.value?.notebooks ?? const <NotebookNode>[]) {
    stdout.writeln('    depth=${n.depth}  直属=${n.directNoteCount}  ${n.name}');
  }

  // 2) 回收站里的目录
  final trashed = await notebooksTrashed();
  stdout.writeln('');
  stdout.writeln('=== notebooksTrashed ===');
  stdout.writeln(
    '  ok=${trashed.ok}  code=${trashed.code}  hint=${trashed.hint}',
  );
  for (final n
      in trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[]) {
    stdout.writeln('    ${n.name}  父=${n.parentId ?? "(顶层)"}');
  }

  // 3) 笔记列表（回收站视图的数据源）
  final notes = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  stdout.writeln('');
  stdout.writeln('=== notesList（含已删）===');
  stdout.writeln('  ok=${notes.ok}  code=${notes.code}  hint=${notes.hint}');
  stdout.writeln('  条数=${notes.value?.notes.length ?? -1}');

  await engineClose();
  exit(0);
}
