// SPDX-License-Identifier: AGPL-3.0-or-later
// 诊断脚本：验证笔记本层级**没有硬性层数限制**，并观察深层级下的树形输出。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/diag_depth.dart
//
// 它在**临时目录**里建库，不会碰你的真实数据。

import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('nested-depth-');
  stdout.writeln('临时数据目录：${dir.path}');
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final now = DateTime.now().millisecondsSinceEpoch;

  // 一条 6 层的链：笔记本 → 子 → 孙 → 曾孙 → 玄孙 → 来孙
  const names = <String>['工作', '项目 A', '阶段一', '任务组', '子任务', '细节'];
  String? parent;
  final ids = <String>[];
  for (final name in names) {
    final r = await notebooksCreate(name: name, parentId: parent, atMs: now);
    if (!r.ok) {
      stderr.writeln('创建「$name」失败：code=${r.code} hint=${r.hint}');
      exit(1);
    }
    final id = r.value!.notebook!.id;
    ids.add(id);
    parent = id;
    stdout.writeln('创建：$name  (parent=${parent == id ? "顶层" : "上一层"})');
  }

  // 每层各放一篇笔记，验证"笔记可以在任意层"
  for (var i = 0; i < ids.length; i++) {
    final r = await notesCreate(
      notebookId: ids[i],
      title: '第 ${i + 1} 层的笔记',
      atMs: now,
    );
    if (!r.ok) {
      stderr.writeln('在某层创建笔记失败：code=${r.code} hint=${r.hint}');
      exit(1);
    }
  }

  // 再建一个"不建子文件夹、直接放笔记"的顶层笔记本
  final flat = await notebooksCreate(
    name: '随手记（无子文件夹）',
    parentId: null,
    atMs: now,
  );
  await notesCreate(
    notebookId: flat.value!.notebook!.id,
    title: '直接放在第一层的笔记',
    atMs: now,
  );

  stdout.writeln('');
  final tree = await notebooksTree();
  if (!tree.ok) {
    stderr.writeln('读取树失败：code=${tree.code} hint=${tree.hint}');
    exit(1);
  }
  final nodes = tree.value!.notebooks;
  stdout.writeln('=== 笔记本树：${nodes.length} 个节点 ===');
  for (final n in nodes) {
    stdout.writeln(
      '${'  ' * n.depth}${n.name}  depth=${n.depth}  '
      '子树笔记数=${n.noteCount}',
    );
  }

  stdout.writeln('');
  stdout.writeln('=== 最大深度 ===');
  final maxDepth = nodes.fold<int>(0, (m, n) => n.depth > m ? n.depth : m);
  stdout.writeln('实际达到的层级深度（顶层为 0）：$maxDepth');
  stdout.writeln('=> 即 ${maxDepth + 1} 层笔记本');

  // 最顶层笔记本应当聚合到全部 6 篇笔记
  final rootCount = nodes.firstWhere((n) => n.depth == 0).noteCount;
  stdout.writeln('');
  stdout.writeln('顶层「工作」的子树笔记数 = $rootCount（应为 6）');

  await engineClose();
  dir.deleteSync(recursive: true);
  stdout.writeln('');
  stdout.writeln('结论：层级没有硬上限（本测试建到第 ${maxDepth + 1} 层）。');
}
