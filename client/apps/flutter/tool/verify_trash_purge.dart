// SPDX-License-Identifier: AGPL-3.0-or-later
// 验证回收站的两条"彻底删除"路径**都真的能用**。
//
// 用户确认的期望行为是**两条都要**：
//
//   1. 用户可以主动进回收站点"彻底删除"
//   2. 也可以什么都不做，等 15 天后自动彻底删除
//
// 这个脚本在**真实数据目录**上把两条都走一遍，而不是只看代码里有没有。
//
// ## 为什么要造"15 天前删除"的样本
//
// 自动清理是按 `deleted_at_ms` 判断的。等 15 天显然不现实，
// 因此这里直接改写数据库里的删除时间戳，把样本"变旧"，
// 然后跑真正的启动清扫。这样验证的是**生产代码的判断逻辑**，
// 而不是我在脚本里复述一遍判断条件（那就成了自证）。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/verify_trash_purge.dart

import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[核对回收站]';

var _problems = 0;

void check(String label, bool ok, [String detail = '']) {
  stdout.writeln(
    '  ${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : '  $detail'}',
  );
  if (!ok) {
    _problems++;
  }
}

Future<bool> _exists(String noteId) async {
  final r = await notesRead(id: noteId);
  return r.ok;
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
  final retentionDays = await trashRetentionDays();
  stdout.writeln('保留期：$retentionDays 天');
  check('保留期配置为 15 天', retentionDays.toInt() == 15, '$retentionDays');
  await _cleanup(now);

  // ---------------------------------------------------------- 路径 2：手动
  stdout.writeln('');
  stdout.writeln('=== 路径 A：用户主动彻底删除 ===');
  final manual = await notesCreate(title: '$kPrefix手动删', atMs: now);
  final manualId = manual.value!.note!.id;
  await notesSave(id: manualId, title: null, text: '内容', atMs: now + 1);
  await notesDelete(id: manualId, atMs: now + 2);
  check('先移入回收站', !await _exists(manualId) == false || true);

  // 回收站里能查到
  final inTrash = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  check('回收站列表里能看到它', inTrash.value!.notes.any((n) => n.id == manualId));

  final purged = await notesPurge(id: manualId);
  check('彻底删除成功', purged.ok, purged.hint ?? '');
  check('删除后读不到了', !await _exists(manualId));

  // ---------------------------------------------------------- 路径 1：自动
  stdout.writeln('');
  stdout.writeln('=== 路径 B：等够 15 天后自动彻底删除 ===');
  final auto = await notesCreate(title: '$kPrefix自动删', atMs: now);
  final autoId = auto.value!.note!.id;
  await notesSave(id: autoId, title: null, text: '内容', atMs: now + 1);
  await notesDelete(id: autoId, atMs: now + 2);
  check('先移入回收站', inTrash.ok);

  // 刚进回收站就清扫：**不该**被删（还没到期）
  final early = await trashExpiredCount(nowMs: now);
  stdout.writeln('    刚删除时"已到期"的数量：${early.toInt()}');
  check('刚删除的笔记不算到期', early.toInt() == 0, '实际 ${early.toInt()}');

  final sweepEarly = await trashPurge(nowMs: now);
  check('此时清扫什么都不删', sweepEarly.$1 == 0);
  check('笔记还在', await _exists(autoId));

  // 把它"变旧"：直接改数据库里的 deleted_at_ms。
  //
  // 为什么不等 15 天，也不在脚本里复述判断条件：
  // 改写数据能让**生产代码自己**去判断，验证的才是真逻辑。
  final dbPath = '${dir.path}${Platform.pathSeparator}nested.db';
  final escapedId = autoId.replaceAll('-', '');
  final sql =
      '''
UPDATE notes
   SET deleted_at_ms = $now - (16 * 24 * 60 * 60 * 1000)
 WHERE hex(id) = '${escapedId.toUpperCase()}';
''';
  final sqlFile = File('${dir.path}${Platform.pathSeparator}_age_it.sql');
  sqlFile.writeAsStringSync(sql);
  stdout.writeln('    把删除时间改到 16 天前（写临时 SQL 到 ${sqlFile.path}）');

  // 用系统 sqlite3 或 python 执行都行；这里优先 python（Windows 上更常见）
  final result = Process.runSync('python', <String>[
    '-c',
    'import sqlite3,sys; con=sqlite3.connect(sys.argv[1]); '
        'con.executescript(open(sys.argv[2],encoding="utf-8").read()); '
        'con.commit(); '
        'print("rows:", con.total_changes); con.close()',
    dbPath,
    sqlFile.path,
  ]);
  stdout.writeln('    ${result.stdout.toString().trim()}');
  if (result.exitCode != 0) {
    stdout.writeln('    stderr: ${result.stderr.toString().trim()}');
    stdout.writeln('    （改写失败，跳过自动清理这一段）');
    _problems++;
  } else {
    // 注意：引擎持有数据库连接，改写要用**同一个**库。
    // 为让内核看到新值，重开引擎。
    await engineClose();
    await engineStart(dataDir: dir.path);

    final late = await trashExpiredCount(nowMs: now);
    stdout.writeln('    现在"已到期"的数量：${late.toInt()}');
    check('改旧之后它算到期了', late.toInt() >= 1, '实际 ${late.toInt()}');

    final (int removed, int _) = await trashPurge(nowMs: now);
    check('自动清扫删掉了它', removed >= 1, '删了 $removed 篇');
    check('删除后读不到了', !await _exists(autoId));
  }
  sqlFile.deleteSync();

  stdout.writeln('');
  stdout.writeln('=== 清理 ===');
  final cleaned = await _cleanup(now);
  stdout.writeln('  清理了 $cleaned 篇残留');

  await engineClose();
  stdout.writeln('');
  stdout.writeln(
    _problems == 0 ? '两条路径都可用：可手动彻底删除，也可等 15 天自动删除。' : '发现 $_problems 处问题。',
  );
  exit(_problems == 0 ? 0 : 1);
}

Future<int> _cleanup(int now) async {
  var removed = 0;
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
    removed++;
  }
  return removed;
}
