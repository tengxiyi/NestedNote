// SPDX-License-Identifier: AGPL-3.0-or-later
// 复现用户报告的第二个症状：
//
//   > 在回收站中删除几个目录后，还是会导致笔记本左侧的目录树不显示了
//
// ## 为什么单独一个脚本
//
// 前一版核对脚本（verify_trash_notebooks）只验证"删目录"这一步本身，
// 而用户报的是**操作之后左栏数据源坏掉**。这两件事在不同的层：
//
// - 删目录 → 数据对不对（已覆盖）
// - 删目录 → `notebooks_tree` 还能不能查（本脚本）
//
// 用户看到的提示是 `CoreError::Database` 的兜底文案，因此必须直接检查
// `notebooksTree()` 的 `ok` 字段，而不是看"列表是不是空的"——
// 那正是踩坑备忘 §7.5 记的混淆：**"查询失败"与"确实没有数据"
// 长得一模一样**，而用户会以为是数据丢了。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/audit_tree_after_purge.dart

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[核对树存活]';

var _problems = 0;

void check(String label, bool ok, [String detail = '']) {
  stdout.writeln(
    '  ${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : '  $detail'}',
  );
  if (!ok) {
    _problems++;
  }
}

/// 左栏数据源的**完整**健康检查。
///
/// 不只看"有几个节点"，而是先看 `ok`——否则查询失败会被读成"目录都没了"。
Future<int> _treeHealth(String when) async {
  final tree = await notebooksTree();
  if (!tree.ok) {
    stdout.writeln('  ✗ $when：notebooksTree **查询失败**');
    stdout.writeln('      code=${tree.code}');
    stdout.writeln('      hint=${tree.hint}');
    stdout.writeln('      debug=${tree.debugDetail}');
    _problems++;
    return -1;
  }
  final int n = tree.value!.notebooks.length;
  stdout.writeln('  ✓ $when：ok，$n 个节点');
  return n;
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

  // 建三个**顶层**目录，每个下面再挂一个子目录——还原"删几个目录"的场景
  final ids = <String>[];
  for (var i = 0; i < 3; i++) {
    final root = await notebooksCreate(
      name: '$kPrefix根$i',
      parentId: null,
      atMs: now + i * 10,
    );
    ids.add(root.value!.notebook!.id);
    await notebooksCreate(
      name: '$kPrefix根$i/子',
      parentId: root.value!.notebook!.id,
      atMs: now + i * 10 + 1,
    );
  }

  stdout.writeln('=== 起点 ===');
  final before = await _treeHealth('建完目录');
  // 基线 = 我造目录**之前**的数量，用于最后核对"清理干净了"。
  // 直接用 $before 会算错：那时我已经加了 6 个（3 根 + 3 子）。
  final int baseline = before - 6;

  // ---------------------------------------------------------- 1. 删掉三个目录
  stdout.writeln('');
  stdout.writeln('=== 1. 逐个删除目录（模拟用户在回收站里操作）===');
  for (final id in ids) {
    final r = await notebooksDeleteSubtree(id: id, atMs: now + 100);
    check('删除一个目录', r.ok, r.hint ?? '');
    // **每次删完都检查一次左栏数据源**：用户是"删几个"之后才发现不对的，
    // 因此关键不是最终状态，而是每一步之后仍然可查。
    await _treeHealth('删掉一个之后');
  }
  final afterDelete = await _treeHealth('三个都删完');
  check(
    '左栏仍可查（数量比起点少 6：3 个根 + 3 个子）',
    afterDelete == before - 6,
    '起点 $before → 现在 $afterDelete',
  );

  // ---------------------------------------------------------- 2. 逐个彻底删除
  stdout.writeln('');
  stdout.writeln('=== 2. 逐个彻底删除（按界面会走的自底向上顺序）===');
  final trashed = await notebooksTrashed();
  final mine =
      (trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
          .where((TrashedNotebook n) => n.name.startsWith(kPrefix))
          .toList()
        // 名称带 '/' 的是子目录，先删它们
        ..sort(
          (TrashedNotebook a, TrashedNotebook b) =>
              b.name.split('/').length.compareTo(a.name.split('/').length),
        );
  check('回收站里能看到它们', mine.length == 6, '实际 ${mine.length}');

  for (final book in mine) {
    final r = await notebooksPurge(id: book.id);
    check('彻底删除「${book.name}」', r.ok, r.hint ?? '');
    // **这一步是关键**：用户的症状正是"删了几个之后左栏就不显示了"。
    await _treeHealth('彻底删除「${book.name}」之后');
  }

  final afterPurge = await _treeHealth('全部彻底删除之后');
  check(
    '左栏回到基线（我造的 6 个都清掉了）',
    afterPurge == baseline,
    '基线 $baseline → 现在 $afterPurge',
  );

  // ---------------------------------------------------------- 3. 重启后再查
  stdout.writeln('');
  stdout.writeln('=== 3. 关引擎重开再查（抓持久化层面的问题）===');
  await engineClose();
  final restarted = await engineStart(dataDir: dir.path);
  check('引擎重启', restarted.ready);
  final afterRestart = await _treeHealth('重启后');
  check('重启后数量不变', afterRestart == baseline, '现在 $afterRestart');

  // ------------------------------------------------- 5. 多轮循环（用户的场景）
  stdout.writeln('');
  stdout.writeln('=== 5. 反复执行多轮"建目录 → 删 → 彻底删" ===');
  // 用户的症状是**操作了几次之后**才出现的，因此单轮通过不算数。
  // 每轮结束都检查一次左栏数据源。
  for (var round = 0; round < 4; round++) {
    final ids = <String>[];
    for (var i = 0; i < 2; i++) {
      final root = await notebooksCreate(
        name: '$kPrefix轮$round-$i',
        parentId: null,
        atMs: now + 1000 + round * 100 + i * 10,
      );
      ids.add(root.value!.notebook!.id);
      await notebooksCreate(
        name: '$kPrefix轮$round-$i/子',
        parentId: root.value!.notebook!.id,
        atMs: now + 1001 + round * 100 + i * 10,
      );
    }
    for (final id in ids) {
      await notebooksDeleteSubtree(id: id, atMs: now + 2000 + round);
    }
    // 回收站里可能混着上一轮没删掉的（模拟用户没一次删干净）
    final t = await notebooksTrashed();
    final pending =
        (t.value?.trashedNotebooks ?? const <TrashedNotebook>[])
            .where((TrashedNotebook n) => n.name.startsWith(kPrefix))
            .toList()
          ..sort(
            (TrashedNotebook a, TrashedNotebook b) =>
                b.name.split('/').length.compareTo(a.name.split('/').length),
          );
    for (final b in pending) {
      await notebooksPurge(id: b.id);
    }
    await _treeHealth('第 ${round + 1} 轮之后');
  }
  final afterRounds = await _treeHealth('四轮全部结束');
  check('四轮之后仍回到基线', afterRounds == baseline, '基线 $baseline → 现在 $afterRounds');

  // ---------------------------------------------------------- 4. 笔记列表也要健康
  stdout.writeln('');
  stdout.writeln('=== 4. 中栏数据源（回收站视图）也要健康 ===');
  final notes = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  check('notesList ok', notes.ok, 'code=${notes.code} hint=${notes.hint}');

  stdout.writeln('');
  stdout.writeln('=== 清理 ===');
  await _cleanup(now);

  await engineClose();
  stdout.writeln('');
  stdout.writeln(_problems == 0 ? '全部通过：删目录不影响左栏数据源。' : '发现 $_problems 处问题。');
  exit(_problems == 0 ? 0 : 1);
}

Future<void> _cleanup(int now) async {
  // 目录：自底向上彻底删
  final trashed = await notebooksTrashed();
  final mine =
      (trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
          .where((TrashedNotebook n) => n.name.startsWith(kPrefix))
          .toList()
        ..sort(
          (TrashedNotebook a, TrashedNotebook b) =>
              b.name.split('/').length.compareTo(a.name.split('/').length),
        );
  for (final b in mine) {
    await notebooksPurge(id: b.id);
  }
  // 还活着的
  final tree = await notebooksTree();
  final live =
      (tree.value?.notebooks ?? const <NotebookNode>[])
          .where((NotebookNode n) => n.name.startsWith(kPrefix))
          .toList()
        ..sort((NotebookNode a, NotebookNode b) => b.depth.compareTo(a.depth));
  for (final b in live) {
    await notebooksDeleteSubtree(id: b.id, atMs: now);
    await notebooksPurge(id: b.id);
  }
}
