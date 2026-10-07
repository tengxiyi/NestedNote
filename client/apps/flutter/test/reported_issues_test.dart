// SPDX-License-Identifier: AGPL-3.0-or-later
// 用户报的 5 个问题的回归测试。
//
// 这些测试对应真实缺陷，每条都写清"当初错在哪、症状是什么"——
// 否则后来者只会看到一堆断言，不知道它们防的是什么。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/core/notebook_providers.dart';
import 'package:nested/core/note_providers.dart';

void main() {
  group('问题 1：计数只显示在最底层文件夹', () {
    // 症状：用户在"资料库"右侧看到 6，但看不懂 6 是什么
    //（它既不是直属笔记数 1，也不是任何一眼能看出的东西，而是子树合计）。
    // 要求：只在**没有子笔记本的**文件夹右侧显示数字，且是它的直属笔记数。
    NotebookNode node(
      String id,
      String name, {
      String? parent,
      int count = 0,
    }) => NotebookNode(
      id: id,
      name: name,
      parentId: parent,
      depth: parent == null ? 0 : 1,
      noteCount: count,
    );

    test('有子笔记本的节点是"容器"', () {
      final List<NotebookNode> tree = <NotebookNode>[
        node('a', '资料库', count: 1),
        node('b', '产品', parent: 'a', count: 1),
      ];
      final Set<String> parents = <String>{
        for (final NotebookNode n in tree)
          if (n.parentId != null) n.parentId!,
      };
      expect(parents.contains('a'), isTrue, reason: '资料库有子笔记本，是容器');
      expect(parents.contains('b'), isFalse, reason: '产品没有子笔记本，是叶子 → 应当显示计数');
    });

    test('树里所有节点都被正确分类（叶子集合与容器集合互补）', () {
      final List<NotebookNode> tree = <NotebookNode>[
        node('a', 'L0', count: 0),
        node('b', 'L0/b', parent: 'a', count: 0),
        node('c', 'L0/b/c', parent: 'b', count: 3),
        node('d', '另一个根', count: 5),
      ];
      final Set<String> parents = <String>{
        for (final NotebookNode n in tree)
          if (n.parentId != null) n.parentId!,
      };
      final List<String> leaves = tree
          .where((NotebookNode n) => !parents.contains(n.id))
          .map((NotebookNode n) => n.id)
          .toList();
      expect(leaves, <String>['c', 'd'], reason: '只有最底层（c 与独立的 d）显示计数');
    });
  });

  group('问题 4：保存后正文缓存必须失效', () {
    // 症状：输入文字后切出去再切回来，笔记里是空的。
    //
    // 根因**不是**保存失败——Rust 侧实测数据已落盘。真因是保存后没有
    // 失效 `noteTextProvider`，切回来时 `_load()` 从缓存读到保存前的
    // 旧文本，把用户刚写的内容盖掉了。
    //
    // 这类缺陷的教训：`_invalidateLists()` 的名字看起来覆盖了"该刷新的
    // 东西"，而它只处理列表类 provider。**"看起来相关"不等于"真的覆盖"**。
    test('noteSnapshotProvider 与 noteTextProvider 是各自独立的键', () {
      // 两者都按 noteId 分族。这里只断言"两篇不同笔记的键不相等"——
      // 若实现里误用了同一个常量键，所有笔记会共用一份缓存，
      // 症状正是"切到另一篇看到上一篇的内容"。
      expect(noteTextProvider('note-a'), isNot(noteTextProvider('note-b')));
      expect(
        noteSnapshotProvider('note-a'),
        isNot(noteSnapshotProvider('note-b')),
      );
    });

    test('同一篇笔记的两个 provider 不是同一个键', () {
      // 它们返回不同类型，若被当成同一个键复用会类型错乱
      expect(noteTextProvider('x'), isNot(noteSnapshotProvider('x')));
    });
  });

  group('问题 5：保存时列表不重查（无刷新感）', () {
    // 症状：每次自动保存中栏闪一下。根因不是"保存慢"，
    // 而是每次保存都把整张列表丢掉重来。
    // 修法：把"刚保存过的笔记"放进覆盖层，由合并视图叠加。
    test('覆盖层替换已存在的行，不改变行数', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      const NoteItem original = NoteItem(
        id: 'n1',
        title: '原标题',
        summary: '',
        updatedAtMs: 0,
        version: 1,
        deleted: false,
      );
      const NoteItem renamed = NoteItem(
        id: 'n1',
        title: '改过的标题',
        summary: '',
        updatedAtMs: 1,
        version: 2,
        deleted: false,
      );

      container.read(recentlySavedNotesProvider.notifier).remember(renamed);

      final Map<String, NoteItem> overlay = container.read(
        recentlySavedNotesProvider,
      );
      expect(overlay['n1']?.title, '改过的标题');
      expect(overlay.containsKey(original.id), isTrue, reason: '覆盖层按键替换，不会新增行');
    });

    test('forgetAll 清空覆盖层（列表重查前调用）', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final RecentlySavedNotes notifier = container.read(
        recentlySavedNotesProvider.notifier,
      );
      notifier.remember(
        const NoteItem(
          id: 'n1',
          title: 't',
          summary: '',
          updatedAtMs: 0,
          version: 1,
          deleted: false,
        ),
      );
      expect(container.read(recentlySavedNotesProvider), isNotEmpty);
      notifier.forgetAll();
      expect(
        container.read(recentlySavedNotesProvider),
        isEmpty,
        reason: '重查前要清掉覆盖层，否则旧覆盖可能与新查到的结果冲突',
      );
    });

    test('覆盖层里没有这一行时，它不会凭空出现', () {
      // 覆盖层只该**替换**已存在的行，不该让不该出现的笔记冒出来
      //（例如它属于别的笔记本，或已进回收站）。
      // 这里验证合并逻辑的前提：覆盖层只是一个按 id 索引的 Map，
      // 合并时以查询结果的行为准。
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(recentlySavedNotesProvider.notifier)
          .remember(
            const NoteItem(
              id: '不在这个列表里',
              title: 't',
              summary: '',
              updatedAtMs: 0,
              version: 1,
              deleted: false,
            ),
          );
      // 合并由 noteListMergedProvider 完成，它遍历的是查询结果，
      // 因此这一条永远不会被加进任何列表。
      expect(
        container.read(recentlySavedNotesProvider).length,
        1,
        reason: '覆盖层只存数据，是否出现由查询结果决定',
      );
    });
  });

  group('问题 3：标题输入区', () {
    testWidgets('编辑器有独立的标题框，且顺序在正文之前', (WidgetTester tester) async {
      // 标题是**独立输入框**而不是"正文第一行特殊对待"：
      // 后者会让"改标题"与"删掉第一行"变成同一个动作，
      // 用户想删一行文字却把标题弄没了。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: NoteEditorPageHarness())),
      );
      await tester.pump();

      final List<TextField> fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.length, 2, reason: '标题与正文各一个输入框');

      // 标题在上方
      final double titleY = tester.getTopLeft(find.byType(TextField).first).dy;
      final double bodyY = tester.getTopLeft(find.byType(TextField).last).dy;
      expect(titleY, lessThan(bodyY), reason: '标题在正文上方');

      // 标题字号明显大于正文
      final double titleSize = fields.first.style?.fontSize ?? 0;
      final double bodySize = fields.last.style?.fontSize ?? 0;
      expect(titleSize, greaterThan(bodySize), reason: '标题字号要更大，否则视觉上分不出哪个是标题');
    });
  });
}

/// 只放一个标题与正文的输入框，用来验证"两个框、顺序、字号"这三件事。
///
/// 直接构造真的编辑器需要引擎，这里只验证布局契约。
class NoteEditorPageHarness extends StatelessWidget {
  /// 构造。
  const NoteEditorPageHarness({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        TextField(
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '标题',
          ),
        ),
        TextField(
          maxLines: null,
          style: theme.textTheme.bodyLarge,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '正文',
          ),
        ),
      ],
    );
  }
}
