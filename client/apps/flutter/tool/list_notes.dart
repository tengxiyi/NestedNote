// SPDX-License-Identifier: AGPL-3.0-or-later
// 诊断脚本：在应用真实数据目录上列出笔记，确认 Rust 侧查询与界面看到的是否一致。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/list_notes.dart

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  stdout.writeln('数据目录：${dir.path}');

  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  stdout.writeln('引擎 ready=${status.ready}  message=${status.message}');
  stdout.writeln('数据库=${status.databasePath}');

  final count = await notesCount();
  stdout.writeln('notesCount = ${count.toInt()}');

  final active = await notesList(includeDeleted: false, limit: 0);
  stdout.writeln('notesList(includeDeleted: false) ok=${active.ok} '
      'code=${active.code} hint=${active.hint}');
  for (final n in active.value?.notes ?? const <NoteSummary>[]) {
    stdout.writeln('  ${n.title}  v${n.version}  '
        'updatedAt=${n.updatedAtMs}  deleted=${n.deleted}');
  }

  final all = await notesList(includeDeleted: true, limit: 0);
  stdout.writeln('notesList(includeDeleted: true) ok=${all.ok} '
      '数量=${all.value?.notes.length}');

  await engineClose();
}
