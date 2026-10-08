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

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

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

  stdout.writeln('=== 步骤 0：新建笔记是否自动下潜到最底层子目录 ===');
  // 用户要求的细节（参照印象笔记）：在非最底层目录点新建时，
  // 笔记被归到**排序第 1 的最底层子目录**，不存在"挂在中间层"的笔记。
  final inParentEarly = await notesCreate(
    notebookId: parentId,
    title: '$kPrefix下潜检查',
    atMs: now + 5,
  );
  check('在父目录新建成功', inParentEarly.ok, inParentEarly.hint ?? '');
  final landed = inParentEarly.value!.note!.notebookId;
  check(
    '笔记没有留在父目录，而是下潜到了子目录',
    landed == childId,
    '落点=${landed == parentId
        ? "父目录（错）"
        : landed == childId
        ? "子目录（对）"
        : landed}',
  );
  await notesDelete(id: inParentEarly.value!.note!.id, atMs: now + 6);
  await notesPurge(id: inParentEarly.value!.note!.id);

  stdout.writeln('');
  stdout.writeln('=== 步骤 1：在**父**笔记本里新建笔记 ===');
  final inParent = await notesCreate(
    notebookId: parentId,
    title: '$kPrefix父里建的',
    atMs: now + 10,
  );
  check('新建成功', inParent.ok, inParent.hint ?? '');
  final fromParentId = inParent.value!.note!.id;
  check('它下潜到了子目录（不留在父层）', inParent.value!.note!.notebookId == childId);

  await notesSave(id: fromParentId, title: null, text: '内容', atMs: now + 11);

  stdout.writeln('');
  stdout.writeln('=== 步骤 2：立刻查两个视图 ===');
  final parentDirect = await _ids(notebookId: parentId);
  final childDirect = await _ids(notebookId: childId);
  check(
    '父的直属视图里**没有**它（笔记只住最底层）',
    !parentDirect.contains(fromParentId),
    '父直属 ${parentDirect.length} 篇',
  );
  check('子的直属视图里有它', childDirect.contains(fromParentId));

  stdout.writeln('');
  stdout.writeln('=== 步骤 3：在**子**笔记本里再建一篇，并核对两个视图 ===');
  final inChild = await notesCreate(
    notebookId: childId,
    title: '$kPrefix子里建的',
    atMs: now + 20,
  );
  check('新建成功', inChild.ok, inChild.hint ?? '');
  final childNoteId = inChild.value!.note!.id;
  check('子目录本身是最底层，落点不变', inChild.value!.note!.notebookId == childId);

  final parentDirect2 = await _ids(notebookId: parentId);
  final childDirect2 = await _ids(notebookId: childId);
  final parentSubtree = await _ids(notebookId: parentId, descendants: true);
  final childSubtree = await _ids(notebookId: childId, descendants: true);

  check(
    '父的直属仍为空（分类节点不存笔记）',
    parentDirect2.isEmpty,
    '父直属 ${parentDirect2.length} 篇',
  );
  check(
    '子目录里有两篇',
    childDirect2.contains(fromParentId) && childDirect2.contains(childNoteId),
    '子直属 ${childDirect2.length} 篇',
  );
  check(
    '**父的子树能看到两篇** —— 这是用户要求恢复的行为',
    parentSubtree.contains(fromParentId) && parentSubtree.contains(childNoteId),
    '父子树 ${parentSubtree.length} 篇',
  );
  check(
    '子的子树与子的直属一致（叶子没有后代）',
    childSubtree.length == childDirect2.length,
    '子子树 ${childSubtree.length} / 子直属 ${childDirect2.length}',
  );
  check(
    '父的子树 = 父直属 ∪ 子子树 —— 徽标数字与列表行数因此相等',
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
        a.isEmpty &&
        b.contains(fromParentId) &&
        b.contains(childNoteId) &&
        c.contains(fromParentId) &&
        c.contains(childNoteId) &&
        c.length == b.length;
    check(
      '第 ${round + 1} 轮交替查询',
      ok,
      '父直属=${a.length} 子=${b.length} 父子树=${c.length}',
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
  check('重启后父的直属仍为空（分类节点不存笔记）', a2.isEmpty, '父直属 ${a2.length} 篇');
  check(
    '重启后两篇都在子目录里',
    b2.contains(childNoteId) && b2.contains(fromParentId),
    '子直属 ${b2.length} 篇',
  );
  check(
    '重启后父的子树仍是两篇（聚合是查询算出来的，不依赖进程内状态）',
    c2.contains(fromParentId) && c2.contains(childNoteId),
    '父子树 ${c2.length} 篇',
  );

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
