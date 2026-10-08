// SPDX-License-Identifier: AGPL-3.0-or-later
// 诊断脚本：直接调用笔记本树与按笔记本过滤的笔记列表，确认内核返回什么。
import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

import 'app_paths.dart';

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  stdout.writeln('数据目录：${dir.path}');
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  stdout.writeln('引擎 ready=${status.ready} message=${status.message}');
  stdout.writeln('');

  final treeResult = await notebooksTree();
  if (!treeResult.ok) {
    stderr.writeln(
      'notebooksTree 失败：code=${treeResult.code} hint=${treeResult.hint}',
    );
    await engineClose();
    exit(1);
  }
  final tree = treeResult.value?.notebooks ?? const <NotebookNode>[];
  stdout.writeln('=== notebooksTree: ${tree.length} 个节点 ===');
  for (final n in tree) {
    stdout.writeln(
      '  ${'  ' * n.depth}${n.name}  '
      'depth=${n.depth} 直属=${n.directNoteCount} 合计=${n.noteCount} parent=${n.parentId ?? "(null)"}',
    );
  }

  stdout.writeln('');
  stdout.writeln('=== 全部笔记 ===');
  final all = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: false,
    limit: 0,
  );
  stdout.writeln(
    'ok=${all.ok} code=${all.code} hint=${all.hint} '
    '数量=${all.value?.notes.length}',
  );
  for (final n in all.value?.notes ?? const <NoteSummary>[]) {
    stdout.writeln('  ${n.title}');
  }

  // 逐个笔记本按树过滤，验证"父级能看到子孙笔记"
  for (final node in tree) {
    final only = await notesList(
      notebookId: node.id,
      includeDescendants: true,
      includeDeleted: false,
      limit: 0,
    );
    stdout.writeln('');
    stdout.writeln(
      '=== 选中「${node.name}」(含子孙) → '
      '${only.value?.notes.length ?? -1} 篇 ===',
    );
    for (final n in only.value?.notes ?? const <NoteSummary>[]) {
      stdout.writeln('  ${n.title}');
    }
  }

  await engineClose();
}
