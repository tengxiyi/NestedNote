// SPDX-License-Identifier: AGPL-3.0-or-later
// 端到端验证"块格式在保存后不丢"。
//
// ## 这条验证要防的是什么
//
// 编辑器的保存路径是"文本 → 块 → 存储"，读回是"块 → 文本"。
// 旧实现把**每一行都变成段落**并**丢掉空行**，后果是：
//
//   一篇有标题/列表/代码块的笔记，在编辑器里保存一次就全变成段落，
//   而且用户看不到任何提示。
//
// 这是**静默的数据形态损失**——最难被发现的一类问题，因为文本一个字
// 都没少，只有结构没了。
//
// ## 本脚本做什么
//
// 建一篇临时笔记 → 写入含各种块标记的文本 → 读回 → 逐项比对
// → 再保存一次确认**幂等**（第二次保存不再改动）→ 清理临时笔记。
//
// 用法：dart run tool/verify_text_projection.dart

import 'dart:io';

import 'package:nested/src/rust/api/branding.dart';
import 'package:nested/src/rust/api/notes.dart' as rust;
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

/// 临时笔记的标题前缀（清理时按它识别；不用固定标题，
/// 因为固定标题会与**上次异常退出留下的残留**撞名而无法区分）。
const String kPrefix = '[验证-投影]';

int _passed = 0;
int _failed = 0;

void check(String what, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    stdout.writeln('  [OK  ] $what');
  } else {
    _failed++;
    stdout.writeln('  [FAIL] $what${detail.isEmpty ? '' : '  —— $detail'}');
  }
}

/// 检查两个字符串的每一行是否逐一相同，不同则打印首个差异。
void checkText(String what, String actual, String expected) {
  if (actual == expected) {
    _passed++;
    stdout.writeln('  [OK  ] $what');
    return;
  }
  _failed++;
  final List<String> a = actual.split('\n');
  final List<String> e = expected.split('\n');
  stdout.writeln('  [FAIL] $what');
  stdout.writeln('         行数 实际=${a.length} 期望=${e.length}');
  final int n = a.length < e.length ? a.length : e.length;
  for (int i = 0; i < n; i++) {
    if (a[i] != e[i]) {
      stdout.writeln('         首个差异在第 ${i + 1} 行');
      stdout.writeln('           实际: ${jsonish(a[i])}');
      stdout.writeln('           期望: ${jsonish(e[i])}');
      break;
    }
  }
}

String jsonish(String s) =>
    '"${s.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"';

Future<void> main(List<String> args) async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await startEngine(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败: ${status.message}');
    exitCode = 1;
    return;
  }
  stdout.writeln('数据库: ${status.databasePath}\n');

  final int now = DateTime.now().millisecondsSinceEpoch;

  // 先清掉上次异常退出可能留下的残留
  await _cleanup(now);

  stdout.writeln('=== 建立临时笔记 ===');
  final created = await rust.notesCreate(title: '$kPrefix源', atMs: now);
  final String? id = created.value?.note?.id;
  if (id == null) {
    stderr.writeln('创建失败: ${created.hint}');
    exitCode = 1;
    return;
  }
  stdout.writeln('  id = $id\n');

  // 这份文本覆盖每一种"格式菜单能产生的"块，以及两种边界情况
  // （空行分段、看起来像标记的普通文本）。
  final String source = <String>[
    '# 一级标题',
    '## 二级标题',
    '',
    '普通段落。',
    '',
    '- 无序项一',
    '- 无序项二',
    '1. 有序项',
    '',
    '- [ ] 未完成的待办',
    '- [x] 已完成的待办',
    '',
    '> 一段引用',
    '',
    '```dart',
    'void main() {}',
    '# 代码里的井号不是标题',
    '```',
    '',
    '---',
    '',
    '结尾段落。',
  ].join('\n');

  try {
    stdout.writeln('=== 保存并读回 ===');
    final saved = await rust.notesSave(
      id: id,
      title: '$kPrefix源',
      text: source,
      atMs: now + 1,
    );
    check('保存成功', saved.ok, saved.hint ?? '');

    final read1 = await rust.notesRead(id: id);
    final String after1 = read1.value?.text ?? '';
    checkText('写入的块标记**原样读回**（格式没被拍平）', after1, source);

    // ---- 幂等：再保存一次不应有任何改动 ----
    //
    // 这一条比上一条更重要。若第二次保存会改动文档，那么每次自动保存
    // 都会产生一条修订，修订历史会被无意义的差异刷满（铁律 T6 的
    // 修订是给人看的）。
    stdout.writeln('\n=== 幂等性（再保存一次）===');
    final saved2 = await rust.notesSave(
      id: id,
      title: '$kPrefix源',
      text: after1,
      atMs: now + 2,
    );
    check('第二次保存成功', saved2.ok, saved2.hint ?? '');
    final after2 = (await rust.notesRead(id: id)).value?.text ?? '';
    checkText('第二次保存**不再改动文档**', after2, after1);

    // ---- 空行分段 ----
    stdout.writeln('\n=== 空行分段 ===');
    const String blank = '第一段\n\n第二段';
    await rust.notesSave(id: id, text: blank, atMs: now + 3);
    final afterBlank = (await rust.notesRead(id: id)).value?.text ?? '';
    checkText('空行保留（按两次回车分段有效）', afterBlank, blank);

    // ---- 不能把普通文本误判成结构 ----
    stdout.writeln('\n=== 普通文本不被误判 ===');
    const String plain = '#没有空格的井号\n-没有空格的减号\n[方括号]不是链接';
    await rust.notesSave(id: id, text: plain, atMs: now + 4);
    final afterPlain = (await rust.notesRead(id: id)).value?.text ?? '';
    checkText('普通文本原样保留', afterPlain, plain);

    // ---- 代码块里的标记不被解析 ----
    stdout.writeln('\n=== 代码块内部的标记不被解析 ===');
    const String fenced = '```\n# 这行在代码块里\n- 这行也在\n```';
    await rust.notesSave(id: id, text: fenced, atMs: now + 5);
    final afterFenced = (await rust.notesRead(id: id)).value?.text ?? '';
    checkText('代码块内容原样保留', afterFenced, fenced);
  } finally {
    stdout.writeln('\n=== 清理 ===');
    await _cleanup(now + 10);
  }

  stdout.writeln('\n通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) {
    exitCode = 1;
  }
}

/// 清掉本脚本产生的临时笔记（含上次异常退出的残留）。
Future<void> _cleanup(int now) async {
  final rust.NoteResult all = await rust.notesList(
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  final List<rust.NoteSummary> notes = all.value?.notes ?? <rust.NoteSummary>[];
  var removed = 0;
  for (final rust.NoteSummary n in notes) {
    if (!n.title.startsWith(kPrefix)) {
      continue;
    }
    // 先进回收站再彻底删除：彻底删除只在回收站里发生（防误触），
    // 这条规则对脚本同样适用——脚本也不该绕过它直接抹数据。
    await rust.notesDelete(id: n.id, atMs: now);
    await rust.notesPurge(id: n.id);
    removed++;
  }
  stdout.writeln('  清理了 $removed 篇临时笔记');
}
