// SPDX-License-Identifier: AGPL-3.0-or-later
// 端到端验证回收站的**笔记本**路径与**批量**彻底删除。
//
// ## 为什么要有这个脚本（这是一条真实的数据丢失路径）
//
// 用户报的原话：
//
//   > 在回收站中逐个进行彻底删除操作时，会导致笔记的目录树丢失。
//   > 关掉软件，重新打开然后再进到回收站中操作彻底删除时，
//   > 删不掉任何里面的笔记了
//
// 排查发现两个缺陷：
//
// 1. **目录能被删除，却没有任何界面能看到或恢复它们**。回收站只列笔记，
//    于是删掉的目录永久消失（子目录与笔记都还在库里，只是看不见）。
// 2. **父目录永远删不掉**。旧清理逻辑"跳过有子节点的笔记本"，
//    导致父节点每轮都被跳过、永久滞留在回收站。
//    真实数据里积了 49 个。
//
// 这个脚本在**真实数据目录**上把修复后的行为跑一遍。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/verify_trash_notebooks.dart

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[核对目录回收]';

var _problems = 0;

void check(String label, bool ok, [String detail = '']) {
  stdout.writeln(
    '  ${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : '  $detail'}',
  );
  if (!ok) {
    _problems++;
  }
}

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final now = DateTime.now().millisecondsSinceEpoch;
  await _cleanup(now);

  // 建一棵三层目录，并在每层放一篇笔记
  final root = await notebooksCreate(
    name: '$kPrefix根',
    parentId: null,
    atMs: now,
  );
  final rootId = root.value!.notebook!.id;
  final mid = await notebooksCreate(
    name: '$kPrefix根/中',
    parentId: rootId,
    atMs: now + 1,
  );
  final midId = mid.value!.notebook!.id;
  final leaf = await notebooksCreate(
    name: '$kPrefix根/中/叶',
    parentId: midId,
    atMs: now + 2,
  );
  final leafId = leaf.value!.notebook!.id;

  final noteIds = <String>[];
  for (final bookId in <String>[rootId, midId, leafId]) {
    // 笔记会自动下潜到最底层（叶子），因此三篇都落在叶里
    final note = await notesCreate(
      notebookId: bookId,
      title: '$kPrefix笔记',
      atMs: now + 3,
    );
    noteIds.add(note.value!.note!.id);
  }

  // ---------------------------------------------------- 1. 目录删除是整棵子树
  stdout.writeln('=== 1. 删除目录应带走整棵子树，不留孤儿 ===');
  final deleted = await notebooksDeleteSubtree(id: rootId, atMs: now + 10);
  check('删除整棵子树成功', deleted.ok, deleted.hint ?? '');

  final tree = await notebooksTree();
  final liveNames = tree.value!.notebooks.map((n) => n.name).toList();
  check(
    '左栏里三个目录都不见了（没有孤儿节点跳出来）',
    !liveNames.any((n) => n.startsWith(kPrefix)),
    '左栏里还有：${liveNames.where((n) => n.startsWith(kPrefix)).toList()}',
  );

  // ---------------------------------------------------- 2. 回收站能看到目录
  stdout.writeln('');
  stdout.writeln('=== 2. 回收站必须能看到已删除的目录 ===');
  final trashed = await notebooksTrashed();
  final trashedNames = trashed.value!.trashedNotebooks
      .map((n) => n.name)
      .toList();
  check(
    '三个目录都出现在回收站里',
    trashedNames.where((n) => n.startsWith(kPrefix)).length == 3,
    '实际 ${trashedNames.where((n) => n.startsWith(kPrefix)).length} 个',
  );
  check(
    '回收站里的目录带删除时间（界面据此算倒计时）',
    trashed.value!.trashedNotebooks
        .where((n) => n.name.startsWith(kPrefix))
        .every((n) => n.deletedAtMs.toInt() > 0),
  );

  // ---------------------------------------------------- 3. 恢复整棵子树
  stdout.writeln('');
  stdout.writeln('=== 3. 恢复目录应带回整棵子树 ===');
  final restored = await notebooksRestoreSubtree(id: rootId);
  check('恢复成功', restored.ok, restored.hint ?? '');

  final tree2 = await notebooksTree();
  final backNames = tree2.value!.notebooks.map((n) => n.name).toList();
  check(
    '三个目录都回到左栏了',
    backNames.where((n) => n.startsWith(kPrefix)).length == 3,
    '实际 ${backNames.where((n) => n.startsWith(kPrefix)).length} 个',
  );
  final trashedAfter = await notebooksTrashed();
  check(
    '它们不再出现在回收站里',
    !trashedAfter.value!.trashedNotebooks.any(
      (n) => n.name.startsWith(kPrefix),
    ),
  );

  // ---------------------------------------------------- 4. 批量彻底删除笔记
  stdout.writeln('');
  stdout.writeln('=== 4. 批量彻底删除笔记 ===');
  for (final id in noteIds) {
    await notesDelete(id: id, atMs: now + 20);
  }
  final inTrash = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  check(
    '三篇都在回收站里',
    inTrash.value!.notes.where((n) => n.title.startsWith(kPrefix)).length == 3,
  );

  final batch = await notesPurgeMany(ids: noteIds);
  check('批量删除调用成功', batch.ok, batch.hint ?? '');
  check(
    '删掉了 3 条',
    batch.value!.batch!.removed.toInt() == 3,
    '实际 ${batch.value!.batch!.removed.toInt()}',
  );
  check('没有失败项', batch.value!.batch!.failed.toInt() == 0);

  final after = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  check(
    '回收站里已经找不到它们',
    !after.value!.notes.any((n) => n.title.startsWith(kPrefix)),
  );

  // ---------------------------------------------------- 5. 部分失败的如实回报
  stdout.writeln('');
  stdout.writeln('=== 5. 批量里混入无效项时的行为 ===');
  final mixed = await notesPurgeMany(ids: <String>[noteIds.first]);
  check(
    '已被删掉的 id 再删一次 → 计入失败而不是成功',
    mixed.ok &&
        mixed.value!.batch!.removed.toInt() == 0 &&
        mixed.value!.batch!.failed.toInt() == 1,
    'removed=${mixed.value!.batch!.removed.toInt()} '
        'failed=${mixed.value!.batch!.failed.toInt()}',
  );

  final badId = await notesPurgeMany(ids: <String>['not-a-uuid']);
  check(
    '含无效 id 时**整批拒绝**，而不是跳过它',
    !badId.ok && badId.code == 'INVALID_ID',
    'code=${badId.code}',
  );

  // ---------------------------------------------------- 6. 目录彻底删除的顺序
  stdout.writeln('');
  stdout.writeln('=== 6. 目录彻底删除必须自底向上 ===');
  await notebooksDeleteSubtree(id: rootId, atMs: now + 30);

  // 先删根：内核必须拒绝（它还有子目录）
  final rootFirst = await notebooksPurge(id: rootId);
  check('先删根会被拒绝（树里还有子目录）', !rootFirst.ok, 'hint=${rootFirst.hint}');

  // 自底向上：叶 → 中 → 根
  final purgeLeaf = await notebooksPurge(id: leafId);
  check('删叶成功', purgeLeaf.ok, purgeLeaf.hint ?? '');
  final purgeMid = await notebooksPurge(id: midId);
  check('删中成功（子已清空）', purgeMid.ok, purgeMid.hint ?? '');
  final purgeRoot = await notebooksPurge(id: rootId);
  check('删根成功（子已清空）', purgeRoot.ok, purgeRoot.hint ?? '');

  final finalTrashed = await notebooksTrashed();
  check(
    '回收站里不再剩下任何本次造出来的目录',
    !finalTrashed.value!.trashedNotebooks.any(
      (n) => n.name.startsWith(kPrefix),
    ),
    '还剩：${finalTrashed.value!.trashedNotebooks.where((n) => n.name.startsWith(kPrefix)).map((n) => n.name).toList()}',
  );

  stdout.writeln('');
  stdout.writeln('=== 清理 ===');
  final cleaned = await _cleanup(now);
  stdout.writeln('  清理了 $cleaned 处残留');

  await engineClose();
  stdout.writeln('');
  stdout.writeln(_problems == 0 ? '全部通过。' : '发现 $_problems 处问题。');
  exit(_problems == 0 ? 0 : 1);
}

/// 清掉本次造出来的东西（含回收站里的目录）。
Future<int> _cleanup(int now) async {
  var cleaned = 0;

  // 笔记：先恢复再删再彻底删（purge 只接受回收站里的）
  final all = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  for (final n in all.value?.notes ?? const <NoteSummary>[]) {
    if (!n.title.startsWith(kPrefix)) {
      continue;
    }
    await notesRestore(id: n.id, atMs: now);
    await notesDelete(id: n.id, atMs: now);
    await notesPurge(id: n.id);
    cleaned++;
  }

  // 目录：自底向上彻底删。**这次的清理逻辑本身就是被修的那个**，
  // 因此这里显式按深度排序，而不是依赖内核的到期清理。
  final trashed = await notebooksTrashed();
  final mine = (trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
      .where((n) => n.name.startsWith(kPrefix))
      .toList();
  // 名称里层数多的先删（'[核对目录回收]根/中/叶' 比 '[核对目录回收]根' 深）
  mine.sort(
    (a, b) => b.name.split('/').length.compareTo(a.name.split('/').length),
  );
  for (final book in mine) {
    await notebooksPurge(id: book.id);
    cleaned++;
  }

  // 还活着的那些也删掉（前面的步骤可能只删了一半）
  final tree = await notebooksTree();
  final live =
      (tree.value?.notebooks ?? const <NotebookNode>[])
          .where((n) => n.name.startsWith(kPrefix))
          .toList()
        ..sort((a, b) => b.depth.compareTo(a.depth));
  for (final book in live) {
    await notebooksDeleteSubtree(id: book.id, atMs: now);
    await notebooksPurge(id: book.id);
    cleaned++;
  }

  return cleaned;
}
