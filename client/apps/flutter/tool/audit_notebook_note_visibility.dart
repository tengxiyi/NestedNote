// SPDX-License-Identifier: AGPL-3.0-or-later
// 核对"同一篇笔记在不同目录下的可见性是否一致"。
//
// ## 这个脚本要回答的问题
//
// 用户报告：在两个不同的目录下预览，看到的中栏笔记列表**内容有差异**
// （不只是数字口径问题，是真实的笔记多出来或少了）。
//
// 之前的排查一直在解释"数字为什么不同"（口径问题），
// 那是**表象**。这里直接把集合拿出来做差集，看哪些笔记对不上。
//
// ## 怎么查
//
// 对每个有子笔记本的节点 N：
//   1. 取 N 的**子树视图**（includeDescendants = true）
//   2. 取 N 的**直属视图**（includeDescendants = false）
//   3. 对每个子节点 C，取 C 的子树视图
//   4. 断言：子树(N) == 直属(N) ∪ 子树(C1) ∪ 子树(C2) ...
//
// 若等式不成立，差集就是"在某个目录下看不到 / 多出来的"那些笔记。
// 这个等式是**数据完整性**的性质，与界面怎么显示无关。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/audit_notebook_note_visibility.dart

import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

import 'app_paths.dart';

Future<List<NoteSummary>> _notes({
  String? notebookId,
  required bool descendants,
}) async {
  final result = await notesList(
    notebookId: notebookId,
    includeDescendants: descendants,
    includeDeleted: false,
    limit: 0,
  );
  if (!result.ok) {
    stderr.writeln('查询失败：${result.hint}');
    exit(1);
  }
  return result.value!.notes;
}

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final treeResult = await notebooksTree();
  final List<NotebookNode> tree = treeResult.value!.notebooks;
  stdout.writeln('笔记本节点：${tree.length} 个');

  final all = await _notes(notebookId: null, descendants: false);
  stdout.writeln('全部笔记（不按笔记本过滤）：${all.length} 篇');
  stdout.writeln('');

  var problems = 0;

  // 每个笔记本的直属笔记 id
  final Map<String, Set<String>> direct = <String, Set<String>>{};
  for (final NotebookNode node in tree) {
    final List<NoteSummary> own = await _notes(
      notebookId: node.id,
      descendants: false,
    );
    direct[node.id] = own.map((NoteSummary n) => n.id).toSet();
  }

  // 1) 交叉核对：每篇笔记的 notebook_id 是否与它出现在哪个"直属视图"里一致
  stdout.writeln('=== 1. 直属视图与笔记归属是否一致 ===');
  final Set<String> seenInDirect = <String>{};
  for (final NotebookNode node in tree) {
    for (final String noteId in direct[node.id]!) {
      if (!seenInDirect.add(noteId)) {
        stdout.writeln('  ✗ 笔记 $noteId 出现在**多个**笔记本的直属视图里');
        problems++;
      }
    }
  }
  // 不在任何笔记本直属视图里的笔记（孤儿）
  final Set<String> allIds = all.map((NoteSummary n) => n.id).toSet();
  final Set<String> orphans = allIds.difference(seenInDirect);
  if (orphans.isNotEmpty) {
    stdout.writeln('  ! ${orphans.length} 篇笔记不属于任何笔记本（正常：未分类笔记）');
  }

  // 2) 核心核对：子树(N) 是否等于 直属(N) ∪ 各子节点子树
  stdout.writeln('');
  stdout.writeln('=== 2. 子树视图是否等于"自身 + 各子节点子树" ===');
  for (final NotebookNode node in tree) {
    final List<NotebookNode> children = tree
        .where((NotebookNode c) => c.parentId == node.id)
        .toList();
    if (children.isEmpty) {
      continue; // 叶子没有子节点，等式退化为"子树 == 直属"，单独验
    }

    final Set<String> subtree = (await _notes(
      notebookId: node.id,
      descendants: true,
    )).map((NoteSummary n) => n.id).toSet();

    final Set<String> expected = <String>{...direct[node.id]!};
    for (final NotebookNode child in children) {
      expected.addAll(
        (await _notes(
          notebookId: child.id,
          descendants: true,
        )).map((NoteSummary n) => n.id),
      );
    }

    final Set<String> missing = expected.difference(subtree);
    final Set<String> extra = subtree.difference(expected);

    if (missing.isEmpty && extra.isEmpty) {
      stdout.writeln(
        '  ✓ ${node.name}  子树=${subtree.length} '
        '（直属 ${direct[node.id]!.length} + 子 ${expected.length - direct[node.id]!.length}）',
      );
    } else {
      problems++;
      stdout.writeln('  ✗ ${node.name}');
      stdout.writeln(
        '      子树视图 ${subtree.length} 篇，'
        '自身+子节点 ${expected.length} 篇',
      );
      for (final String id in missing) {
        stdout.writeln('      **少了**：${_titleOf(all, id)}  ($id)');
      }
      for (final String id in extra) {
        stdout.writeln('      **多了**：${_titleOf(all, id)}  ($id)');
      }
    }
  }

  // 3) 叶子节点：子树应当等于直属
  stdout.writeln('');
  stdout.writeln('=== 3. 叶子节点：子树视图是否等于直属视图 ===');
  for (final NotebookNode node in tree) {
    final bool isLeaf = !tree.any((NotebookNode c) => c.parentId == node.id);
    if (!isLeaf) {
      continue;
    }
    final Set<String> subtree = (await _notes(
      notebookId: node.id,
      descendants: true,
    )).map((NoteSummary n) => n.id).toSet();
    final Set<String> own = direct[node.id]!;
    if (subtree.length == own.length && subtree.containsAll(own)) {
      stdout.writeln('  ✓ ${node.name}  两视图一致（${own.length} 篇）');
    } else {
      problems++;
      stdout.writeln('  ✗ ${node.name}  子树=${subtree.length} 直属=${own.length}');
    }
  }

  // 4) 顶层：所有笔记本子树之和 vs 全部笔记
  stdout.writeln('');
  stdout.writeln('=== 4. 各顶层子树之和 vs 全部笔记 ===');
  final Set<String> fromRoots = <String>{};
  for (final NotebookNode node in tree.where(
    (NotebookNode n) => n.parentId == null,
  )) {
    fromRoots.addAll(
      (await _notes(
        notebookId: node.id,
        descendants: true,
      )).map((NoteSummary n) => n.id),
    );
  }
  final Set<String> notInAnyRoot = allIds.difference(fromRoots);
  stdout.writeln(
    '  全部笔记 ${allIds.length} 篇；'
    '顶层子树合计 ${fromRoots.length} 篇；'
    '不在任何顶层子树里 ${notInAnyRoot.length} 篇',
  );
  for (final String id in notInAnyRoot) {
    stdout.writeln('      ${_titleOf(all, id)}  ($id)');
  }

  stdout.writeln('');
  stdout.writeln(problems == 0 ? '核对通过：没有发现不一致。' : '发现 $problems 处不一致。');
  await engineClose();
  exit(problems == 0 ? 0 : 1);
}

String _titleOf(List<NoteSummary> all, String id) {
  for (final NoteSummary n in all) {
    if (n.id == id) {
      return n.title.isEmpty ? '(无标题)' : n.title;
    }
  }
  return '(未知标题)';
}
