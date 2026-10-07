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
  dump('创建后', await _history(id));

  final first = await notesSave(
    id: id,
    title: null,
    text: '内容 A',
    atMs: now + 1000,
  );
  stdout.writeln('保存1 后 version=${first.value!.note!.version.toInt()}');
  dump('保存1 后', await _history(id));

  final second = await notesSave(
    id: id,
    title: null,
    text: '内容 A',
    atMs: now + 2000,
  );
  stdout.writeln('保存2（内容相同）后 version=${second.value!.note!.version.toInt()}');
  dump('保存2 后', await _history(id));

  await engineClose();
  dir.deleteSync(recursive: true);
}

/// 取修订历史（解开 NoteResult；失败直接报错退出）。
///
/// `notes_revision_history` 现在返回 NoteResult 而不是裸 List——
/// 失败会带错误码，而不是静默返回空列表（那会让"查询失败"与"没有历史"长得一样）。
Future<List<RevisionEntry>> _history(String id) async {
  final result = await notesRevisionHistory(id: id, limit: 0);
  if (!result.ok) {
    stderr.writeln('读取修订历史失败：code=${result.code} hint=${result.hint}');
    exit(1);
  }
  return result.value?.revisions ?? const <RevisionEntry>[];
}
