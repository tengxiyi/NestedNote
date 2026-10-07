// SPDX-License-Identifier: AGPL-3.0-or-later
// 一次性脚本：在应用真实数据目录里造一套示例数据（笔记本树 + 笔记），
// 用于人工观察三栏界面效果。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/seed_demo_notes.dart          # 造示例数据
//   dart run tool/seed_demo_notes.dart --clean  # 清空示例数据
//
// 清理规则：笔记本名以「[示例]」开头、笔记标题以「[示例]」开头，都只清这些，
// 不会碰你自己的数据。

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[示例]';

/// 示例笔记本树：`(名称, 父名称, 该笔记本下的笔记)`。
///
/// 父名称用 `null` 表示顶层。用名称而不是 id 是为了让这份数据可读、
/// 可维护——脚本内部会先建笔记本拿到 id 再引用。
const List<(String, String?, List<(String, String)>)> kTree =
    <(String, String?, List<(String, String)>)>[
      (
        '工作',
        null,
        <(String, String)>[
          (
            '项目约定',
            '所有结构变更都必须新增一条迁移文件，已发布的迁移不可修改。\n'
                '启动时按 user_version 顺序执行，整体在一个事务里，失败即中止。\n'
                '这样能保证新装用户与老用户的 schema 不会悄悄分叉。',
          ),
        ],
      ),
      (
        '工作 / 进行中',
        '工作',
        <(String, String)>[
          (
            '三栏布局的职责划分',
            '左栏只负责选择笔记本，不查笔记。\n'
                '中栏只负责当前笔记本下的笔记列表，不关心树的形状。\n'
                '右栏只负责展示与编辑一篇笔记。\n'
                '这样任何一栏的数据变化都不会迫使另外两栏重算。',
          ),
          (
            '笔记本树过滤',
            '用户在树里点选父笔记本时，期望看到它以及所有后代的笔记。\n'
                '否则每建一层子笔记本，父级看上去就变空了。\n'
                '实现上用递归 CTE 一次查完，避免把 id 列表拼进 SQL。',
          ),
        ],
      ),
      (
        '技术笔记',
        null,
        <(String, String)>[
          (
            '为什么用块模型',
            '不用 HTML 或 Markdown 作为核心存储格式：\n'
                '它们把内容与呈现绑在一起，跨端渲染结果不可控。\n'
                '块模型让每个语义单元独立，便于局部更新、同步与导出。',
          ),
          (
            '内容寻址存储',
            '文件名不是标识：同一张图改名、复制、粘贴进两篇笔记，都是同一份内容。\n'
                '因此路径由内容哈希决定，天然去重。\n'
                '写入流程是临时文件 → fsync → rename，保证原子性。',
          ),
        ],
      ),
      (
        '技术笔记 / 数据',
        '技术笔记',
        <(String, String)>[
          (
            '写入顺序不可颠倒',
            '附件横跨文件系统与数据库，两处无法共享一个事务。\n'
                '因此必须明确哪一半先落：\n'
                '先文件后库 → 残留孤儿文件（安全，可回收）\n'
                '先库后文件 → 残留断链（危险，用户看到"附件损坏"）\n'
                '判据是：让残留物是可回收的垃圾，而不是用户可见的故障。',
          ),
        ],
      ),
      (
        '读书',
        null,
        <(String, String)>[
          (
            '设计数据密集型应用',
            '第 2 部分讲分布式数据，重点是复制与分区。\n'
                '待办：整理一份关于 CRDT 的笔记。',
          ),
        ],
      ),
    ];

Future<void> main(List<String> args) async {
  final bool clean = args.contains('--clean');
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final now = DateTime.now().millisecondsSinceEpoch;
  await _clean(now);

  if (clean) {
    stdout.writeln('已清理示例数据。');
    await engineClose();
    return;
  }

  // 名称 → id，用于把子笔记本挂到正确的父节点上
  final Map<String, String> ids = <String, String>{};

  for (final (name, parentName, notes) in kTree) {
    final created = await notebooksCreate(
      name: '$kPrefix$name',
      parentId: parentName == null ? null : ids[parentName],
      atMs: now,
    );
    if (!created.ok) {
      stderr.writeln('创建笔记本「$name」失败：${created.hint}');
      continue;
    }
    final notebookId = created.value!.notebook!.id;
    ids[name] = notebookId;
    stdout.writeln(
      '笔记本 $kPrefix$name  '
      '${parentName == null ? '(顶层)' : '↳ $kPrefix$parentName'}',
    );

    for (final (title, body) in notes) {
      final note = await notesCreate(
        notebookId: notebookId,
        title: '$kPrefix$title',
        atMs: now,
      );
      if (!note.ok) {
        stderr.writeln('  创建笔记「$title」失败：${note.hint}');
        continue;
      }
      final saved = await notesSave(
        id: note.value!.note!.id,
        text: body,
        atMs: now,
      );
      if (!saved.ok) {
        stderr.writeln('  保存笔记「$title」失败：${saved.hint}');
        continue;
      }
      stdout.writeln('  笔记 $kPrefix$title');
    }
  }

  await engineClose();
  stdout.writeln('');
  stdout.writeln('数据目录：${dir.path}');
  stdout.writeln('运行应用即可看到三栏布局（左栏为多层级笔记本树）。');
}

/// 清掉此前造的示例数据。
///
/// 顺序很重要：**先删笔记再删笔记本**。反过来的话，笔记本先被软删，
/// 其下笔记就出现在"任何笔记本之外"，清理时不容易再按笔记本定位。
Future<void> _clean(int now) async {
  final existing = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  for (final note in existing.value?.notes ?? const <NoteSummary>[]) {
    if (!note.title.startsWith(kPrefix)) {
      continue;
    }
    await notesRestore(id: note.id, atMs: now);
    await notesDelete(id: note.id, atMs: now);
  }

  // 笔记本：从**最深**的开始删，避免父级先消失导致子级变成孤儿节点
  final treeResult = await notebooksTree();
  final List<NotebookNode> tree =
      treeResult.value?.notebooks ?? const <NotebookNode>[];
  final demo = tree.where((n) => n.name.startsWith(kPrefix)).toList()
    ..sort((a, b) => b.depth.compareTo(a.depth));
  for (final node in demo) {
    await notebooksDelete(id: node.id, atMs: now);
  }
  if (demo.isNotEmpty) {
    stdout.writeln('已清理 ${demo.length} 个示例笔记本与其下笔记。');
  }
}
