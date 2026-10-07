// SPDX-License-Identifier: AGPL-3.0-or-later
// 按**用户的操作序列**核对笔记归属，而不是单次调用。
//
// ## 为什么需要它
//
// 前面的核对脚本（audit_notebook_note_visibility）证明"任何时刻的树与集合
// 都是自洽的"。但用户报告的是**在实际操作过程中**看到差异——
// 这类缺陷恰恰不会出现在"静止状态"的核对里：
// 每一步单独看都对，按顺序连起来才暴露（踩坑备忘 §7.2 记的就是这一类）。
//
// 因此这里完整重放用户描述的步骤：
//
//   1. 在父笔记本里新建笔记
//   2. 立刻查父视图与子视图
//   3. 用 UI 实际会用的那组参数再查一遍（limit / includeDeleted / includeDescendants）
//   4. 关掉引擎重开（模拟重启），再查一遍
//
// 每一步都要求：新建的笔记**只**出现在它所属笔记本的直属视图里，
// **不**出现在任何兄弟/子笔记本的直属视图里，但**要**出现在祖先的子树视图里。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/audit_note_assignment.dart

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[核对归属]';

var _problems = 0;

void check(String label, bool ok, [String detail = '']) {
  stdout.writeln(
    '  ${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : '  $detail'}',
  );
  if (!ok) {
    _problems++;
  }
}

Future<List<NoteSummary>> _list({
  String? notebookId,
  bool descendants = false,
}) async {
  final r = await notesList(
    notebookId: notebookId,
    includeDescendants: descendants,
    includeDeleted: false,
    limit: 0,
  );
  if (!r.ok) {
    stderr.writeln('查询失败：${r.hint}');
    exit(1);
  }
  return r.value!.notes;
}

Future<Set<String>> _ids({String? notebookId, bool descendants = false}) async {
  final list = await _list(notebookId: notebookId, descendants: descendants);
  return list.map((NoteSummary n) => n.id).toSet();
}

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  var status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final now = DateTime.now().millisecondsSinceEpoch;
  await _cleanup(now);

  // 建一棵两级树：父 → 子（还原用户说的"工作1 / 工作1 下的进行中1"）
  final parent = await notebooksCreate(
    name: '$kPrefix父',
    parentId: null,
    atMs: now,
  );
  if (!parent.ok) {
    stderr.writeln('建父笔记本失败：${parent.hint}');
    exit(1);
  }
  final parentId = parent.value!.notebook!.id;
  final child = await notebooksCreate(
    name: '$kPrefix子',
    parentId: parentId,
    atMs: now + 1,
  );
  if (!child.ok) {
    stderr.writeln('建子笔记本失败：${child.hint}');
    exit(1);
  }
  final childId = child.value!.notebook!.id;

  stdout.writeln('=== 步骤 1：在**父**笔记本里新建笔记 ===');
  final inParent = await notesCreate(
    notebookId: parentId,
    title: '$kPrefix父里的笔记',
    atMs: now + 10,
  );
  check('新建成功', inParent.ok, inParent.hint ?? '');
  final parentNoteId = inParent.value!.note!.id;

  await notesSave(id: parentNoteId, title: null, text: '父里的内容', atMs: now + 11);

  stdout.writeln('');
  stdout.writeln('=== 步骤 2：立刻查两个视图 ===');
  final parentDirect = await _ids(notebookId: parentId);
  final childDirect = await _ids(notebookId: childId);
  check('父的直属视图里有它', parentDirect.contains(parentNoteId));
  check('**子**的直属视图里没有它（它不属于子）', !childDirect.contains(parentNoteId));

  stdout.writeln('');
  stdout.writeln('=== 步骤 3：在**子**笔记本里新建笔记，再查 ===');
  final inChild = await notesCreate(
    notebookId: childId,
    title: '$kPrefix子里的笔记',
    atMs: now + 20,
  );
  check('新建成功', inChild.ok, inChild.hint ?? '');
  final childNoteId = inChild.value!.note!.id;

  final parentDirect2 = await _ids(notebookId: parentId);
  final childDirect2 = await _ids(notebookId: childId);
  final parentSubtree = await _ids(notebookId: parentId, descendants: true);
  final childSubtree = await _ids(notebookId: childId, descendants: true);

  check('父的直属：只有父里那篇', !parentDirect2.contains(childNoteId));
  check('子的直属：只有子里那篇', !childDirect2.contains(parentNoteId));
  check(
    '父的子树：两篇都有',
    parentSubtree.contains(parentNoteId) && parentSubtree.contains(childNoteId),
    '${parentSubtree.length} 篇',
  );
  check(
    '子的子树：只有子里那篇',
    !childSubtree.contains(parentNoteId),
    '${childSubtree.length} 篇',
  );
  check(
    '父的子树 = 父直属 ∪ 子子树',
    parentSubtree.length == parentDirect2.union(childSubtree).length,
    '父子树 ${parentSubtree.length} / 并集 ${parentDirect2.union(childSubtree).length}',
  );

  stdout.writeln('');
  stdout.writeln('=== 步骤 4：反复交替查询（抓缓存/时序问题）===');
  for (var round = 0; round < 5; round++) {
    final a = await _ids(notebookId: parentId);
    final b = await _ids(notebookId: childId);
    final c = await _ids(notebookId: parentId, descendants: true);
    final ok =
        a.contains(parentNoteId) &&
        !a.contains(childNoteId) &&
        b.contains(childNoteId) &&
        !b.contains(parentNoteId) &&
        c.contains(parentNoteId) &&
        c.contains(childNoteId);
    check(
      '第 ${round + 1} 轮交替查询',
      ok,
      '父=${a.length} 子=${b.length} 父子树=${c.length}',
    );
  }

  stdout.writeln('');
  stdout.writeln('=== 步骤 5：关引擎重开，再查（抓持久化问题）===');
  await engineClose();
  status = await engineStart(dataDir: dir.path);
  check('引擎重启', status.ready);

  final a2 = await _ids(notebookId: parentId);
  final b2 = await _ids(notebookId: childId);
  final c2 = await _ids(notebookId: parentId, descendants: true);
  check(
    '重启后父的直属仍只有父里那篇',
    a2.contains(parentNoteId) && !a2.contains(childNoteId),
  );
  check(
    '重启后子的直属仍只有子里那篇',
    b2.contains(childNoteId) && !b2.contains(parentNoteId),
  );
  check('重启后父的子树仍是两篇', c2.contains(parentNoteId) && c2.contains(childNoteId));

  // 逐篇核对归属字段与所在视图是否一致
  stdout.writeln('');
  stdout.writeln('=== 步骤 6：逐篇核对"归属字段"与"它出现在哪个直属视图" ===');
  final all = await _list();
  final parentList = await _list(notebookId: parentId);
  final childList = await _list(notebookId: childId);
  for (final NoteSummary n in <NoteSummary>[...parentList, ...childList]) {
    final inParentList = parentList.any((NoteSummary x) => x.id == n.id);
    final inChildList = childList.any((NoteSummary x) => x.id == n.id);
    check(
      '「${n.title}」只出现在一个直属视图里',
      inParentList != inChildList,
      '父=$inParentList 子=$inChildList',
    );
  }
  check('总计只多了我们造的 2 篇', all.length >= 2);

  stdout.writeln('');
  stdout.writeln('=== 清理 ===');
  final removed = await _cleanup(now);
  stdout.writeln('  清理了 $removed 篇笔记与 2 个笔记本');

  await engineClose();
  stdout.writeln('');
  stdout.writeln(_problems == 0 ? '全部通过：归属与可见性处处一致。' : '发现 $_problems 处不一致。');
  exit(_problems == 0 ? 0 : 1);
}

Future<int> _cleanup(int now) async {
  var removed = 0;
  final all = await notesList(
    notebookId: null,
    includeDescendants: false,
    includeDeleted: true,
    limit: 0,
  );
  for (final NoteSummary n in all.value?.notes ?? const <NoteSummary>[]) {
    if (!n.title.startsWith(kPrefix)) {
      continue;
    }
    await notesRestore(id: n.id, atMs: now);
    await notesDelete(id: n.id, atMs: now);
    await notesPurge(id: n.id);
    removed++;
  }
  final tree = await notebooksTree();
  final books =
      (tree.value?.notebooks ?? const <NotebookNode>[])
          .where((NotebookNode n) => n.name.startsWith(kPrefix))
          .toList()
        ..sort((NotebookNode a, NotebookNode b) => b.depth.compareTo(a.depth));
  for (final NotebookNode n in books) {
    await notebooksDelete(id: n.id, atMs: now);
  }
  return removed;
}
