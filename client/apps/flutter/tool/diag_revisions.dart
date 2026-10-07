// SPDX-License-Identifier: AGPL-3.0-or-later
// 诊断脚本：观察"保存 → 修订记录"的真实行为，定位多出来的那一条。
import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

void dump(String label, List<RevisionEntry> list) {
  stdout.writeln('--- $label: ${list.length} 条 ---');
  for (final r in list) {
    stdout.writeln(
      '   v${r.version} op=${r.operation} '
      'parent=${r.parentId?.substring(0, 8) ?? "(null)"} '
      'id=${r.id.substring(0, 8)} device=${r.deviceId}',
    );
  }
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('nested-diag-');
  stdout.writeln('临时目录 ${dir.path}');
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  stdout.writeln('引擎 ready=${status.ready}');

  final now = DateTime.now().millisecondsSinceEpoch;

  final created = await notesCreate(title: '保存语义', atMs: now);
  final id = created.value!.note!.id;
  stdout.writeln('创建后 version=${created.value!.note!.version.toInt()}');
  dump('创建后', await notesRevisionHistory(id: id, limit: 0));

  final first = await notesSave(id: id, text: '内容 A', atMs: now + 1000);
  stdout.writeln('保存1 后 version=${first.value!.note!.version.toInt()}');
  dump('保存1 后', await notesRevisionHistory(id: id, limit: 0));

  final second = await notesSave(id: id, text: '内容 A', atMs: now + 2000);
  stdout.writeln('保存2（内容相同）后 version=${second.value!.note!.version.toInt()}');
  dump('保存2 后', await notesRevisionHistory(id: id, limit: 0));

  await engineClose();
  dir.deleteSync(recursive: true);
}
