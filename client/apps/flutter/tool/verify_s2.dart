// SPDX-License-Identifier: AGPL-3.0-or-later
// 一次性脚本：在应用真实数据目录里跑一遍 S2 的三条主路径，
// 确认它们在**真实存储**上端到端可用（而不只是单元测试里）。
//
// 用法（client/apps/flutter 目录下）：
//   dart run tool/verify_s2.dart
//
// 跑完后会把造出来的东西清掉，不污染示例数据。

import 'dart:io';

import 'package:nestednote/src/rust/api/notes.dart';
import 'package:nestednote/src/rust/frb_generated.dart';

import 'app_paths.dart';

const String kPrefix = '[验证S2]';

Future<void> main() async {
  final dir = resolveAppDataDirForTools();
  await RustLib.init();
  final status = await engineStart(dataDir: dir.path);
  if (!status.ready) {
    stderr.writeln('引擎启动失败：${status.message}');
    exit(1);
  }

  final now = DateTime.now().millisecondsSinceEpoch;

  // 先清掉上次运行可能留下的东西，让脚本**可重复运行**。
  // （第一版没有这步，第二次跑就撞上"标签重名"而失败。）
  await _cleanup(now);

  var failures = 0;
  void check(String label, bool ok, [String detail = '']) {
    stdout.writeln(
      '  ${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : '  $detail'}',
    );
    if (!ok) {
      failures++;
    }
  }

  stdout.writeln('=== 1. 标签名复用（技术债 #13）===');
  final createdTag = await tagsCreate(name: '$kPrefix工作', atMs: now);
  check('创建标签', createdTag.ok, createdTag.hint ?? '');
  final tagId = createdTag.value!.tags.first.id;

  // 直接删掉它，然后同名重建
  final tagDeleted = await tagsDelete(id: tagId, atMs: now + 1);
  check('删除标签', tagDeleted.ok, tagDeleted.hint ?? '');
  final listed1 = await tagsList();
  check('删除后不出现在列表里', !listed1.value!.tags.any((t) => t.id == tagId));

  final recreated = await tagsCreate(name: '$kPrefix工作', atMs: now + 2);
  check('同名标签可以重建', recreated.ok, recreated.hint ?? '');
  if (recreated.ok) {
    check(
      '复用了原来的 id（复活而不是新建）',
      recreated.value!.tags.first.id == tagId,
      'new=${recreated.value!.tags.first.id.substring(0, 8)} '
          'old=${tagId.substring(0, 8)}',
    );
  }

  stdout.writeln('');
  stdout.writeln('=== 2. 笔记深拷贝 ===');
  final book = await notebooksCreate(
    name: '$kPrefix本子',
    parentId: null,
    atMs: now,
  );
  check('创建笔记本', book.ok, book.hint ?? '');
  final bookId = book.value!.notebook!.id;

  final note = await notesCreate(
    notebookId: bookId,
    title: '$kPrefix原件',
    atMs: now,
  );
  check('创建笔记', note.ok, note.hint ?? '');
  final noteId = note.value!.note!.id;
  await notesSave(id: noteId, title: null, text: '第一行\n第二行', atMs: now + 1);

  // 给原件打标签
  final tagIdFinal = recreated.value!.tags.first.id;
  final tagged = await notesSetTags(
    id: noteId,
    tagIds: <String>[tagIdFinal],
    atMs: now + 2,
  );
  check('给笔记打标签', tagged.ok, tagged.hint ?? '');
  final noteTags = await notesListTags(id: noteId);
  check('读回标签', noteTags.value!.tags.length == 1);

  final dup = await notesDuplicate(id: noteId, atMs: now + 3);
  check('复制笔记', dup.ok, dup.hint ?? '');
  if (dup.ok) {
    final copyId = dup.value!.note!.id;
    check('副本是新 id', copyId != noteId);
    check(
      '标题带副本后缀',
      dup.value!.note!.title.endsWith('（副本）'),
      dup.value!.note!.title,
    );
    check('副本从第 1 版开始', dup.value!.note!.version.toInt() == 1);

    final copyTags = await notesListTags(id: copyId);
    check('标签一起复制', copyTags.value!.tags.length == 1);

    final copyHistory = await notesRevisionHistory(id: copyId, limit: 0);
    check(
      '修订历史**不**复制（副本只有自己那一条）',
      copyHistory.value!.revisions.length == 1,
      '实际 ${copyHistory.value!.revisions.length} 条',
    );

    final copyText = await notesRead(id: copyId);
    check(
      '正文一致',
      copyText.value!.text!.contains('第一行') &&
          copyText.value!.text!.contains('第二行'),
      copyText.value!.text!.replaceAll('\n', r'\n'),
    );
  }

  stdout.writeln('');
  stdout.writeln('=== 3. 笔记本深拷贝（递归）===');
  final child = await notebooksCreate(
    name: '$kPrefix子本子',
    parentId: bookId,
    atMs: now,
  );
  final childNote = await notesCreate(
    notebookId: child.value!.notebook!.id,
    title: '$kPrefix子笔记',
    atMs: now,
  );
  await notesSave(
    id: childNote.value!.note!.id,
    title: null,
    text: '子内容',
    atMs: now + 1,
  );

  final bookDup = await notebooksDuplicate(id: bookId, atMs: now + 4);
  check('复制笔记本', bookDup.ok, bookDup.hint ?? '');
  if (bookDup.ok) {
    final newBookId = bookDup.value!.notebook!.id;
    check('副本是新 id', newBookId != bookId);
    check(
      '根名称带副本后缀',
      bookDup.value!.notebook!.name.endsWith('（副本）'),
      bookDup.value!.notebook!.name,
    );

    final source = await notesList(
      notebookId: bookId,
      includeDescendants: true,
      includeDeleted: false,
      limit: 0,
    );
    final copied = await notesList(
      notebookId: newBookId,
      includeDescendants: true,
      includeDeleted: false,
      limit: 0,
    );
    stdout.writeln(
      '    原件树里的笔记：'
      '${source.value!.notes.map((n) => n.title).join(", ")}',
    );
    stdout.writeln(
      '    副本树里的笔记：'
      '${copied.value!.notes.map((n) => n.title).join(", ")}',
    );
    check(
      '副本树与原件树的笔记数一致',
      copied.value!.notes.length == source.value!.notes.length,
      '原件 ${source.value!.notes.length} 篇 / 副本 ${copied.value!.notes.length} 篇',
    );

    final tree = await notebooksTree();
    final names = tree.value!.notebooks.map((n) => n.name).toList();
    final suffixCount = names
        .where((n) => n.startsWith(kPrefix) && n.endsWith('（副本）'))
        .length;
    check('只有子树根带后缀', suffixCount == 1, '带后缀的：$suffixCount 个');
  }

  stdout.writeln('');
  stdout.writeln('=== 清理 ===');
  final (notes, books, tags) = await _cleanup(now);
  stdout.writeln('  清理了 $notes 篇笔记、$books 个笔记本、$tags 个标签');

  await engineClose();
  stdout.writeln('');
  stdout.writeln(failures == 0 ? '全部通过。' : '有 $failures 项失败。');
  exit(failures == 0 ? 0 : 1);
}

/// 清掉本脚本造出来的东西，返回 (笔记数, 笔记本数, 标签数)。
///
/// 顺序：**先笔记、再笔记本、最后标签**。
/// 反过来会让笔记失去归属（笔记本没了），清理时不容易再按前缀定位。
///
/// 标签不会被"彻底删除"（内核没有硬删标签的接口，也不该有）——
/// 只需软删即可，它就不再出现在列表里。
Future<(int, int, int)> _cleanup(int now) async {
  var notes = 0;
  final all = await notesList(
    notebookId: null,
    includeDescendants: true,
    includeDeleted: true,
    limit: 0,
  );
  for (final item in all.value?.notes ?? const <NoteSummary>[]) {
    if (!item.title.startsWith(kPrefix)) {
      continue;
    }
    await notesRestore(id: item.id, atMs: now);
    await notesDelete(id: item.id, atMs: now);
    await notesPurge(id: item.id);
    notes++;
  }

  final tree = await notebooksTree();
  final books =
      tree.value?.notebooks.where((n) => n.name.startsWith(kPrefix)).toList() ??
            <NotebookNode>[]
        ..sort((a, b) => b.depth.compareTo(a.depth));
  for (final node in books) {
    await notebooksDelete(id: node.id, atMs: now);
  }

  var tags = 0;
  final tagList = await tagsList();
  for (final tag in tagList.value?.tags ?? const <TagEntry>[]) {
    if (tag.name.startsWith(kPrefix)) {
      await tagsDelete(id: tag.id, atMs: now);
      tags++;
    }
  }
  return (notes, books.length, tags);
}
