// SPDX-License-Identifier: AGPL-3.0-or-later
// 笔记本树过滤与上下文菜单的测试。
//
// ## 为什么给"过滤"单独写测试
//
// 过滤规则里有两条不变量，它们都不是"能跑就行"的细节：
//
// 1. **父命中保留整棵子树**——用户搜"工作"时期望看到它下面有什么，
//    而不是只剩一个孤零零的父节点；
// 2. **子命中保留所有祖先**——否则命中的节点在树里会失去深度位置，
//    渲染出来缩进全错。
//
// 这两条一旦被改坏，界面表现为"搜出来的树层级是乱的"，
// 而肉眼评审很难发现。所以写成测试。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/icons.dart';
import 'package:nested/app/notebook_sidebar.dart';
import 'package:nested/core/notebook_providers.dart';

/// 造一个笔记本节点。
NotebookNode nb({
  required String id,
  required String name,
  String? parentId,
  int depth = 0,
}) => NotebookNode(
  id: id,
  name: name,
  parentId: parentId,
  depth: depth,
  noteCount: 0,
);

/// 一棵用于过滤测试的树：
///
/// ```text
/// 工作            (w)
///   项目 A         (a)
///     需求         (r)
/// 生活            (l)
///   账单          (b)
/// ```
final List<NotebookNode> kTree = <NotebookNode>[
  nb(id: 'w', name: '工作'),
  nb(id: 'a', name: '项目 A', parentId: 'w', depth: 1),
  nb(id: 'r', name: '需求', parentId: 'a', depth: 2),
  nb(id: 'l', name: '生活'),
  nb(id: 'b', name: '账单', parentId: 'l', depth: 1),
];

/// 在给定关键字下运行过滤器，返回保留下来的名称。
///
/// 注意 overrides 不写显式类型：Riverpod 3 未公开 Override 这个类型名
/// （本项目已两次踩到）。
/// **必须先 await 树的 future 再读过滤器**：`filteredNotebookTreeProvider`
/// 是同步 `Provider`，它读的是 `notebooksTreeProvider.value`。
/// 若不等异步数据到位就读，会拿到 `null`，过滤结果恒为空——
/// 本测试第一版就是这样全线失败的。
Future<List<String>> filteredNames(String keyword) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [notebooksTreeProvider.overrideWith((Ref ref) async => kTree)],
  );
  addTearDown(container.dispose);
  await container.read(notebooksTreeProvider.future);
  container.read(notebookFilterProvider.notifier).set(keyword);
  return container
      .read(filteredNotebookTreeProvider)
      .map((NotebookNode node) => node.name)
      .toList();
}

void main() {
  group('笔记本树过滤', () {
    test('空关键字返回整棵树', () async {
      expect(await filteredNames(''), hasLength(5));
      expect(await filteredNames('   '), hasLength(5), reason: '纯空格等于没过滤');
    });

    test('命中父节点时保留它的整棵子树', () async {
      // 这条是核心：搜"工作"要能看到它下面有什么
      expect(await filteredNames('工作'), <String>['工作', '项目 A', '需求']);
    });

    test('命中子节点时保留它的所有祖先', () async {
      // 若只留"需求"，它会因为父节点被过滤掉而在树里失去位置
      expect(await filteredNames('需求'), <String>[
        '工作',
        '项目 A',
        '需求',
      ], reason: '命中项的所有祖先都必须保留，否则层级与缩进都不成立');
    });

    test('过滤后仍保持原有的深度优先顺序', () async {
      // 过滤只做"隐藏"，绝不重排
      final List<String> names = await filteredNames('需求');
      expect(names, <String>['工作', '项目 A', '需求']);
    });

    test('大小写不敏感', () async {
      expect(await filteredNames('项目 a'), contains('项目 A'));
      expect(await filteredNames('项目 A'), contains('项目 A'));
    });

    test('无命中时返回空列表', () async {
      expect(await filteredNames('不存在的名字'), isEmpty);
    });

    test('命中多个无关分支时都保留各自的祖先链', () async {
      final List<String> names = await filteredNames('单');
      // 只命中"账单"→ 保留 生活 + 账单
      expect(names, <String>['生活', '账单']);
    });
  });

  group('左栏控件', () {
    testWidgets('提供过滤输入框', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notebooksTreeProvider.overrideWith((Ref ref) async => kTree),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 240, child: NotebookSidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, '查找笔记本'),
        findsOneWidget,
        reason: '树内过滤是"笔记本多了以后"的必要入口',
      );
    });

    testWidgets('过滤输入后树只显示命中的分支', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notebooksTreeProvider.overrideWith((Ref ref) async => kTree),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 240, child: NotebookSidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('生活'), findsOneWidget);
      expect(find.text('账单'), findsOneWidget);

      // 关键字刻意不写成任何一行的完整名称：否则 `find.text` 会同时命中
      // 输入框里的文字与树里的行，断言变成"找到 2 个"而失败
      // （本测试第一版就踩了这个）。
      await tester.enterText(find.byType(TextField), '需');
      await tester.pumpAndSettle();

      // 命中链保留：自己 + 所有祖先
      expect(find.text('工作'), findsOneWidget);
      expect(find.text('项目 A'), findsOneWidget);
      expect(find.text('需求'), findsOneWidget);
      // 无关分支被隐藏
      expect(find.text('生活'), findsNothing);
      expect(find.text('账单'), findsNothing);
    });

    testWidgets('无匹配时给出可读提示而不是空白', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notebooksTreeProvider.overrideWith((Ref ref) async => kTree),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 240, child: NotebookSidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();

      // 空白面板会让用户以为树坏了；必须说清是"没匹配"
      expect(find.textContaining('没有匹配'), findsOneWidget);
    });

    testWidgets('用层级图标区分深度', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notebooksTreeProvider.overrideWith((Ref ref) async => kTree),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 240, child: NotebookSidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      IconData iconOf(String label) {
        final Finder tile = find.ancestor(
          of: find.text(label),
          matching: find.byType(NotebookTreeTile),
        );
        return tester
            .widget<Icon>(
              find
                  .descendant(of: tile.first, matching: find.byType(Icon))
                  .first,
            )
            .icon!;
      }

      expect(
        <IconData>{iconOf('工作'), iconOf('项目 A'), iconOf('需求')},
        hasLength(3),
        reason: '顶层 / 第二层 / 第三层必须是三个不同的文件夹图标',
      );
    });

    testWidgets('"全部笔记"入口始终存在且带专用图标', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notebooksTreeProvider.overrideWith((Ref ref) async => kTree),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 240, child: NotebookSidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('全部笔记'), findsOneWidget);
      expect(find.byIcon(kAllNotesIcon), findsOneWidget);
    });
  });
}
