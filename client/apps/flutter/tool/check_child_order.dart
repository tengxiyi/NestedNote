import 'dart:io';
import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';
import 'app_paths.dart';

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  await engineStart(dataDir: dir.path);
  final now = DateTime.now().millisecondsSinceEpoch;

  final parent = await notebooksCreate(
    name: '[排序核对]父',
    parentId: null,
    atMs: now,
  );
  final pid = parent.value!.notebook!.id;
  for (final n in ['丙', '甲', '乙']) {
    await notebooksCreate(name: n, parentId: pid, atMs: now + 1);
  }

  final tree = await notebooksTree();
  stdout.writeln('左栏（树）里这个父目录的子节点顺序：');
  var inSubtree = false;
  for (final node in tree.value!.notebooks) {
    if (node.name == '[排序核对]父') {
      inSubtree = true;
      continue;
    }
    if (inSubtree && node.depth == 1 && ['丙', '甲', '乙'].contains(node.name)) {
      stdout.writeln('   ${node.name}');
    }
  }

  // 新建笔记，看它落到哪个子目录
  final note = await notesCreate(
    notebookId: pid,
    title: '[排序核对]笔记',
    atMs: now + 2,
  );
  final landed = note.value!.note!.notebookId;
  final target = tree.value!.notebooks.firstWhere((n) => n.id == landed);
  stdout.writeln('');
  stdout.writeln('新建的笔记落到了：${target.name}');

  // 清理
  final all = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  for (final n in all.value!.notes.where((n) => n.title.startsWith('[排序核对]'))) {
    await notesRestore(id: n.id, atMs: now);
    await notesDelete(id: n.id, atMs: now);
    await notesPurge(id: n.id);
  }
  final tree2 = await notebooksTree();
  final books =
      tree2.value!.notebooks
          .where(
            (n) =>
                n.name.startsWith('[排序核对]') || ['丙', '甲', '乙'].contains(n.name),
          )
          .toList()
        ..sort((a, b) => b.depth.compareTo(a.depth));
  for (final b in books) {
    await notebooksDelete(id: b.id, atMs: now);
  }
  await engineClose();
}
