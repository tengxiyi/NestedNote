// SPDX-License-Identifier: AGPL-3.0-or-later
// 一次性：把最后一个脚本残留目录（`甲`）连同它里面的残留笔记一起清掉。
//
// ## 为什么需要第二步
//
// 直接 `notebooksPurge` 被内核**正确地拒绝了**：
//
//   这个目录里还有没删除的笔记，或者下面还有子目录。
//
// 那是护栏在起作用——它不允许"彻底删除目录"顺手销毁还活着的笔记。
// 因此正确顺序是：先把里面的笔记也删掉（那是我造的 `[排序核对]笔记`），
// 再删目录。
//
// 这个顺序本身也验证了护栏是有效的：如果它没拦住，我就是在**静默销毁
// 一篇还活着的笔记**。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/cleanup_last_residue.dart --apply

import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

import 'app_paths.dart';

/// 已知的脚本残留目录名（这些单字目录是为"验证中文排序规则"造的，
/// 与 `[排序核对]父` 配套）。
const Set<String> kKnownResidueNames = <String>{'甲', '乙', '丙'};

Future<void> main(List<String> args) async {
  final bool apply = args.contains('--apply');
  await RustLib.init();
  final status = await engineStart(dataDir: resolveAppDataDirForTools().path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final now = DateTime.now().millisecondsSinceEpoch;

  // 1) 先找出那些残留目录
  final trashed = await notebooksTrashed();
  final targets = (trashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
      .where((TrashedNotebook n) => kKnownResidueNames.contains(n.name))
      .toList();
  final Set<String> targetIds = targets
      .map((TrashedNotebook t) => t.id)
      .toSet();

  stdout.writeln(
    '残留目录 ${targets.length} 个：'
    '${targets.map((TrashedNotebook t) => t.name).toList()}',
  );

  if (targets.isEmpty) {
    stdout.writeln('无需清理。');
    await engineClose();
    exit(0);
  }

  // 2) 找出**挂在它们下面**的笔记（含活着的）
  final allNotes = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  final inside = (allNotes.value?.notes ?? const <NoteSummary>[])
      .where((NoteSummary n) => targetIds.contains(n.notebookId))
      .toList();

  stdout.writeln('挂在它们下面的笔记 ${inside.length} 篇：');
  for (final n in inside) {
    stdout.writeln('  ${n.deleted ? "回收站" : "**活着**"}  ${n.title}');
  }

  if (!apply) {
    stdout.writeln('');
    stdout.writeln('（预览。加 --apply 真的删除。）');
    await engineClose();
    exit(0);
  }

  // 3) 笔记：活的先删，再彻底删
  for (final n in inside) {
    if (!n.deleted) {
      await notesDelete(id: n.id, atMs: now);
    }
    final result = await notesPurge(id: n.id);
    stdout.writeln(
      '  ${result.ok ? "已彻底删除" : "失败：${result.hint}"}  ${n.title}',
    );
  }

  // 4) 目录：自底向上（按名称层数），多轮收敛
  var removed = 0;
  for (var pass = 0; pass < 4; pass++) {
    final current = await notebooksTrashed();
    final batch = (current.value?.trashedNotebooks ?? const <TrashedNotebook>[])
        .where((TrashedNotebook n) => kKnownResidueNames.contains(n.name))
        .toList();
    if (batch.isEmpty) {
      break;
    }
    var changed = false;
    for (final t in batch) {
      final result = await notebooksPurge(id: t.id);
      if (result.ok) {
        removed++;
        changed = true;
        stdout.writeln('  已彻底删除目录「${t.name}」');
      }
    }
    if (!changed) {
      break;
    }
  }

  stdout.writeln('');
  stdout.writeln('删除了 $removed 个目录。');

  final finalTrashed = await notebooksTrashed();
  final leftover =
      (finalTrashed.value?.trashedNotebooks ?? const <TrashedNotebook>[])
          .where((TrashedNotebook n) => kKnownResidueNames.contains(n.name))
          .length;
  if (leftover > 0) {
    stdout.writeln('仍有 $leftover 个未能删除——它们下面还挂着东西。');
  }

  await engineClose();
  exit(0);
}
