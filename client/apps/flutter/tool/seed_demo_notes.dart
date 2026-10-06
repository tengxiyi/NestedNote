// SPDX-License-Identifier: AGPL-3.0-or-later
// 一次性脚本：在应用真实数据目录里造几篇示例笔记，用于人工观察界面效果。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/seed_demo_notes.dart          # 造示例数据
//   dart run tool/seed_demo_notes.dart --clean  # 清空示例数据
//
// 只有标题以「[示例]」开头的笔记会被清理，不会碰你自己的数据。

import 'dart:io';

import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[示例]';


Future<void> main(List<String> args) async {
  final bool clean = args.contains('--clean');
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  // 先清掉旧的示例笔记（避免重复运行时堆一堆）
  final existing = await notesList(includeDeleted: true, limit: 0);
  for (final note in existing.value?.notes ?? const <NoteSummary>[]) {
    if (note.title.startsWith(kPrefix)) {
      await notesRestore(id: note.id, atMs: DateTime.now().millisecondsSinceEpoch);
      await notesDelete(id: note.id, atMs: DateTime.now().millisecondsSinceEpoch);
    }
  }

  if (clean) {
    stdout.writeln('已清理示例笔记。');
    await engineClose();
    return;
  }

  const samples = <(String, String)>[
    (
      '项目约定',
      '所有结构变更都必须新增一条迁移文件，已发布的迁移不可修改。\n'
          '启动时按 user_version 顺序执行，整体在一个事务里，失败即中止。\n'
          '这样可以保证新装用户与老用户的 schema 不会悄悄分叉。',
    ),
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
    (
      '读书记录',
      '《设计数据密集型应用》—— 第 2 部分讲分布式数据，重点是复制与分区。\n'
          '待办：整理一份关于 CRDT 的笔记。',
    ),
  ];

  final now = DateTime.now().millisecondsSinceEpoch;
  for (int i = 0; i < samples.length; i++) {
    final (title, body) = samples[i];
    final created = await notesCreate(
      title: '$kPrefix$title',
      atMs: now + i * 1000,
    );
    if (!created.ok) {
      stderr.writeln('创建失败：${created.hint}');
      continue;
    }
    final id = created.value!.note!.id;
    final saved = await notesSave(id: id, text: body, atMs: now + i * 1000 + 500);
    if (!saved.ok) {
      stderr.writeln('保存失败：${saved.hint}');
      continue;
    }
    stdout.writeln('已创建：$kPrefix$title');
  }

  await engineClose();
  stdout.writeln('');
  stdout.writeln('数据目录：${dir.path}');
  stdout.writeln('现在运行应用即可看到这些笔记（exe 或 flutter run -d windows）。');
}
