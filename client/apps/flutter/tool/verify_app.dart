// SPDX-License-Identifier: AGPL-3.0-or-later
// 端到端验证：在**应用真实数据目录**上跑完整笔记闭环。
//
// 与 `ffi_integration_test.dart` 的区别：
// - 后者用临时目录，属于自动化测试；
// - 本脚本用 `%APPDATA%\app.nestednote\nested`（打包后的 exe 实际使用的位置），
//   因此它验证的是"用户装完应用后会看到什么"。
//
// ## 用法（仓库根目录）
//
// ```powershell
// powershell -NoProfile -File scripts/verify-app.ps1
// ```
//
// 脚本会：构建 release 动态库 → 运行本验证 → 报告结果。
// **不会**删除你的笔记数据；写入的验证笔记会被标记后自动移入回收站。

import 'dart:io';

import 'package:nested/src/rust/api/branding.dart';
import 'package:nested/src/rust/api/notes.dart';
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';


int _failed = 0;

void check(String label, bool condition, [String? detail]) {
  final mark = condition ? '[OK  ]' : '[FAIL]';
  stdout.writeln('$mark $label${detail == null ? '' : '  → $detail'}');
  if (!condition) {
    _failed++;
  }
}

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  stdout.writeln('数据目录：${dir.path}');
  stdout.writeln('');

  await RustLib.init();

  // 品牌与版本来自 branding API（EngineStatus 只描述启动自检本身）
  final info = await versionInfo();
  final nameZh = await displayName(languageTag: 'zh-CN');

  // --- 1. 启动引擎 ---
  final status = await engineStart(dataDir: dir.path);
  check('引擎启动', status.ready, status.message ?? '');
  for (final c in status.checks) {
    check('  自检 ${c.name}', c.passed);
  }
  check('显示名来自 Rust', nameZh == '拾光笔记', nameZh);
  stdout.writeln('  版本 ${info.version}　协议 v${info.protocolVersion}');
  stdout.writeln('  数据库 ${status.databasePath}');
  stdout.writeln('');

  // --- 2. 记录初始状态（不干扰用户既有数据）---
  final before = await notesList(includeDeleted: false, limit: 0);
  final int beforeCount = before.value?.notes.length ?? 0;
  stdout.writeln('现有笔记：$beforeCount 篇');
  stdout.writeln('');

  // --- 3. 完整闭环 ---
  final now = DateTime.now().millisecondsSinceEpoch;
  final created = await notesCreate(title: '[验证] 拾光笔记', atMs: now);
  check('创建笔记', created.ok, created.hint ?? '');
  final id = created.value!.note!.id;

  const text = '第一行：写入成功\n第二行：块模型按行存储\n第三行：可以读回';
  final saved = await notesSave(id: id, text: text, atMs: now + 1000);
  check('保存正文', saved.ok, saved.hint ?? '');
  check('修订号递增', saved.value!.note!.version.toInt() == 2,
      'v${saved.value!.note!.version}');
  check('摘要取首行', saved.value!.note!.summary == '第一行：写入成功',
      saved.value!.note!.summary);

  final read = await notesRead(id: id);
  check('读回内容一致', read.value?.text == text, read.value?.text ?? '(null)');

  final after = await notesList(includeDeleted: false, limit: 0);
  check('出现在列表中', (after.value?.notes.length ?? 0) == beforeCount + 1,
      '现在 ${after.value?.notes.length ?? 0} 篇');

  // --- 4. 关闭再打开：验证持久化 ---
  check('关闭引擎（释放文件锁）', await engineClose());
  final reopened = await engineStart(dataDir: dir.path);
  check('重新启动引擎', reopened.ready, reopened.message ?? '');
  final afterRestart = await notesRead(id: id);
  check('重启后内容仍在', afterRestart.value?.text == text,
      afterRestart.value?.text ?? '(null)');

  // --- 5. 清理：软删除验证笔记（可从回收站恢复，不物理删除）---
  final deleted = await notesDelete(id: id, atMs: now + 2000);
  check('验证笔记移入回收站', deleted.ok, deleted.hint ?? '');

  await engineClose();

  stdout.writeln('');
  if (_failed == 0) {
    stdout.writeln('结论：全部通过。桌面应用的笔记闭环可用。');
    exit(0);
  }
  stdout.writeln('结论：$_failed 项失败。');
  exit(1);
}
