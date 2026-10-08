// SPDX-License-Identifier: AGPL-3.0-or-later
// 中栏列表在**切换目录**时是否正确跟着变。
//
// ## 为什么单独测这一层
//
// 用户报告"两个不同目录下看到的笔记列表有差异"。排查顺序是：
//
// 1. 内核/数据库的集合核对（audit_notebook_note_visibility）→ 一致
// 2. 用户操作序列重放，含引擎重启与交替查询（audit_note_assignment）→ 一致
// 3. **界面层在切换目录时是否正确重算**（本文件）
//
// 前两层都过了，因此剩下的可疑面只有第 3 层。这里把"每个目录返回什么"
// 做成可控的假数据，专门验证：**换了目录之后，中栏显示的是新目录的笔记**。
//
// 这类缺陷的典型形态是"provider 缓存键不对"或"widget 复用了旧状态"——
// 两者都只在**连续切换**时才暴露，单看一个目录永远是对的。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nestednote/app/notes_page.dart';
import 'package:nestednote/core/engine_providers.dart';
import 'package:nestednote/core/notebook_providers.dart';
import 'package:nestednote/core/note_providers.dart';

import 'widget_test.dart' show fakeEngineStatus;

/// 两个笔记本，各自有**不同数量、不同标题**的笔记。
const String kParentId = 'parent-id';
const String kChildId = 'child-id';

List<NoteItem> _notesFor(String? notebookId) {
  NoteItem item(String id, String title) => NoteItem(
    id: id,
    title: title,
    summary: '',
    updatedAtMs: 0,
    version: 1,
    deleted: false,
  );
  return switch (notebookId) {
    // 父目录：只有它自己那一篇
    kParentId => <NoteItem>[item('p1', '父里的笔记')],
    // 子目录：三篇
    kChildId => <NoteItem>[
      item('c1', '子里的笔记甲'),
      item('c2', '子里的笔记乙'),
      item('c3', '子里的笔记丙'),
    ],
    // 全部笔记：四篇
    _ => <NoteItem>[
      item('p1', '父里的笔记'),
      item('c1', '子里的笔记甲'),
      item('c2', '子里的笔记乙'),
      item('c3', '子里的笔记丙'),
    ],
  };
}

Widget _harness({String? initialNotebook}) {
  return ProviderScope(
    overrides: [
      engineProvider.overrideWith((Ref ref) async => fakeEngineStatus()),
      notebooksTreeProvider.overrideWith(
        (Ref ref) async => <NotebookNode>[
          const NotebookNode(
            id: kParentId,
            name: '父目录',
            parentId: null,
            depth: 0,
            noteCount: 4,
            directNoteCount: 1,
          ),
          const NotebookNode(
            id: kChildId,
            name: '父目录/子目录',
            parentId: kParentId,
            depth: 1,
            noteCount: 3,
            directNoteCount: 3,
          ),
        ],
      ),
      // 按查询参数返回不同数据：模拟内核的正确行为
      noteListProvider.overrideWith(
        (Ref ref, NoteListQuery query) async => _notesFor(query.notebookId),
      ),
      if (initialNotebook != null)
        selectedNotebookIdProvider.overrideWith(_FixedSelection.new),
    ],
    child: const MaterialApp(home: NotesPage()),
  );
}

/// 固定初值的选中笔记本。
class _FixedSelection extends SelectedNotebook {
  @override
  String? build() => kParentId;
}

void main() {
  group('中栏在两目录间切换时显示正确', () {
    testWidgets('从"全部笔记"切到父目录，列表跟着变', (WidgetTester tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // 起始："全部笔记" → 4 篇
      expect(find.text('父里的笔记'), findsOneWidget);
      expect(find.text('子里的笔记甲'), findsOneWidget);
      expect(find.text('4 篇笔记'), findsOneWidget, reason: '表头数字应等于行数');

      // 切到父目录 → 只剩它自己那篇
      await tester.tap(find.text('父目录'));
      await tester.pumpAndSettle();

      expect(find.text('父里的笔记'), findsOneWidget);
      expect(find.text('子里的笔记甲'), findsNothing, reason: '切到父目录后，子目录的笔记必须消失');
      expect(find.text('1 篇笔记'), findsOneWidget);
    });

    testWidgets('父目录 → 子目录 → 父目录，来回都对', (WidgetTester tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // 父
      await tester.tap(find.text('父目录'));
      await tester.pumpAndSettle();
      expect(find.text('1 篇笔记'), findsOneWidget, reason: '父目录 1 篇');
      expect(find.text('子里的笔记甲'), findsNothing);

      // 子
      await tester.tap(find.text('父目录/子目录'));
      await tester.pumpAndSettle();
      expect(find.text('3 篇笔记'), findsOneWidget, reason: '子目录 3 篇');
      expect(find.text('子里的笔记甲'), findsOneWidget);
      expect(find.text('父里的笔记'), findsNothing, reason: '切到子目录后，父目录的笔记必须消失');

      // 回到父 —— 这一步是关键：若 provider 缓存键或 widget 状态有错，
      // "回去"时最容易看到上一个目录的残留
      await tester.tap(find.text('父目录'));
      await tester.pumpAndSettle();
      expect(find.text('1 篇笔记'), findsOneWidget, reason: '回到父目录仍是 1 篇');
      expect(find.text('子里的笔记甲'), findsNothing, reason: '回到父目录后，子目录的笔记不能残留');
    });

    testWidgets('反复切换 4 轮，每轮数字都对', (WidgetTester tester) async {
      // 用户的症状是"两个目录看到的数量不一致"。
      // 若存在缓存/时序缺陷，通常在反复切换几次后才显现。
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      for (var round = 0; round < 4; round++) {
        await tester.tap(find.text('父目录'));
        await tester.pumpAndSettle();
        expect(
          find.text('1 篇笔记'),
          findsOneWidget,
          reason: '第 ${round + 1} 轮：父目录应为 1 篇',
        );

        await tester.tap(find.text('父目录/子目录'));
        await tester.pumpAndSettle();
        expect(
          find.text('3 篇笔记'),
          findsOneWidget,
          reason: '第 ${round + 1} 轮：子目录应为 3 篇',
        );
      }
    });

    testWidgets('表头数字始终等于列表行数', (WidgetTester tester) async {
      // 这是用户实际会数的那两个数字。它们必须相等，
      // 否则"看起来对不上"的体验会一直存在。
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      Future<void> assertHeaderMatchesRows(String where) async {
        final AsyncValue<List<NoteItem>> state = ProviderScope.containerOf(
          tester.element(find.byType(NotesPage)),
        ).read(noteListMergedProvider(_currentQuery(tester)));
        final int rows = state.value?.length ?? 0;
        expect(
          find.text('$rows 篇笔记'),
          findsOneWidget,
          reason: '$where：表头应显示 $rows（与行数一致）',
        );
      }

      await tester.tap(find.text('父目录'));
      await tester.pumpAndSettle();
      await assertHeaderMatchesRows('父目录');

      await tester.tap(find.text('父目录/子目录'));
      await tester.pumpAndSettle();
      await assertHeaderMatchesRows('子目录');
    });
  });
}

/// 读出界面当前用的查询（与 NoteListPane 里的构造方式保持一致）。
NoteListQuery _currentQuery(WidgetTester tester) {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(NotesPage)),
  );
  return NoteListQuery(notebookId: container.read(selectedNotebookIdProvider));
}
