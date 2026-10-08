// SPDX-License-Identifier: AGPL-3.0-or-later
// 在**真实数据**上验证"文本 ↔ 块"往返是稳定的。
//
// ## 为什么必须在真实数据上验
//
// 单元测试用的是构造出来的块。而真实库里的笔记是历次编辑攒下来的，
// 可能含有没预料到的形态（空行位置、只有空格的段落、恰好以 `-` 开头的
// 正文、代码块围栏……）。往返在这些数据上是否稳定，只有真跑一遍才知道。
//
// ## 为什么"稳定"就够，不要求"逐字不变"
//
// 投影规则把一些写法**归一**（连续空行合成一个、末尾空行裁掉、
// 标题层级夹到 1–6）。这些都是有意的。真正要保证的性质是
// **归一之后不再变化**——否则每次保存都会改动文档，
// 修订历史会被无意义的差异刷满。
//
// 因此本脚本检查的是：
//   1. 第二次往返必须与第一次**逐字相同**（不稳定 = 严重问题）；
//   2. 第一次往返与原文的差异**如实报出来**，让人看见归一发生在哪。
//
// ## 本脚本**只读**
//
// 只调 `roundTripText`（纯函数，不碰数据库）与读操作，不写任何数据。
//
// 用法：dart run tool/audit_round_trip.dart

import 'dart:io';

import 'package:nested/src/rust/api/branding.dart';
import 'package:nested/src/rust/api/notes.dart' as rust;
import 'package:nested/src/rust/frb_generated.dart';

import 'app_paths.dart';

/// 一条笔记的检查结论。
class _Finding {
  _Finding(this.title, this.problems);

  final String title;
  final List<String> problems;

  bool get unstable => problems.isNotEmpty;
}

Future<void> main(List<String> args) async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await startEngine(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败: ${status.message}');
    exitCode = 1;
    return;
  }
  stdout.writeln('引擎就绪，数据库: ${status.databasePath}\n');

  final notes = await rust.notesList(
    includeDeleted: false,
    includeDescendants: true,
    // 0 = 尽可能多（FFI 会把它映射到 MAX_PAGE_SIZE）
    limit: 0,
  );
  final list = notes.value?.notes ?? const [];
  stdout.writeln('可读笔记: ${list.length} 篇');

  final List<_Finding> findings = [];
  int withStructure = 0;
  int normalizedCount = 0;

  for (final note in list) {
    final read = await rust.notesRead(id: note.id);
    final String body = read.value?.text ?? '';

    // 第一次往返
    final once = (await rust.roundTripText(text: body)).value?.text ?? '';
    // 第二次往返：必须与第一次完全相同
    final twice = (await rust.roundTripText(text: once)).value?.text ?? '';

    final List<String> problems = [];
    if (twice != once) {
      problems.add('**不稳定**：第二次往返仍在变化（每次保存都会产生修订）');
    }
    if (once != body) {
      normalizedCount++;
    }
    if (_hasStructure(body)) {
      withStructure++;
    }
    findings.add(_Finding(note.title, problems));
  }

  final unstable = findings.where((f) => f.unstable).toList();
  stdout.writeln('含结构标记（# / - / > / ``` / ---）的笔记: $withStructure 篇');
  stdout.writeln('第一次往返发生归一（预期内）的笔记: $normalizedCount 篇');
  stdout.writeln('往返**不稳定**的笔记: ${unstable.length} 篇\n');

  for (final f in unstable) {
    stdout.writeln('  「${f.title}」');
    for (final p in f.problems) {
      stdout.writeln('      - $p');
    }
  }

  if (unstable.isEmpty) {
    stdout.writeln('结论：全部笔记的文本投影在归一之后都是**稳定**的。');
    stdout.writeln('      也就是说，在编辑器里反复保存不会改动文档，');
    stdout.writeln('      也不会产生无意义的修订记录。');
  } else {
    stdout.writeln('结论：有 ${unstable.length} 篇笔记的往返不稳定，需要检查投影规则。');
    exitCode = 1;
  }
}

/// 文本里是否含结构标记。
bool _hasStructure(String text) {
  for (final line in text.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('# ') ||
        t.startsWith('- ') ||
        t.startsWith('> ') ||
        t.startsWith('```') ||
        t == '---') {
      return true;
    }
  }
  return false;
}
