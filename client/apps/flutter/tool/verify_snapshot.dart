import 'dart:io';
import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';
import 'app_paths.dart';

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  stdout.writeln('引擎 ready=${status.ready}');
  final now = DateTime.now().millisecondsSinceEpoch;

  final created = await notesCreate(title: '[验证]快照', atMs: now);
  final id = created.value!.note!.id;
  await notesSave(id: id, title: null, text: '第一版内容', atMs: now + 1000);
  await notesSave(id: id, title: null, text: '第二版内容', atMs: now + 2000);

  final history = await notesRevisionHistory(id: id, limit: 0);
  stdout.writeln('修订数=${history.value!.revisions.length}');
  final count = await notesRevisionSnapshotCount(id: id);
  stdout.writeln('带快照的修订数=${count.toInt()}');

  final revs = history.value!.revisions;
  if (revs.length >= 2) {
    final diff = await notesRevisionDiff(oldId: revs[1].id, newId: revs[0].id);
    final d = diff.value!.diff!;
    stdout.writeln(
      '对比 v${d.older.version} → v${d.newer.version}  '
      'missing=${d.missingSnapshot}  +${d.added} -${d.removed}',
    );
    for (final l in d.lines) {
      stdout.writeln('   ${l.kind}: ${l.text}');
    }
  }
  await notesDelete(id: id, atMs: now + 3000);
  await notesPurge(id: id);
  stdout.writeln('已清理验证笔记');
  await engineClose();
}
