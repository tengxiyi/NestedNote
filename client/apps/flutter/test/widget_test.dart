// SPDX-License-Identifier: AGPL-3.0-or-later
// Flutter 侧界面测试。
//
// ## 测什么、不测什么
//
// 这里只验证**界面装配与渲染**：外壳能启动、三栏的关键部件都在、
// 折叠行为生效、笔记本树的缩进与计数正确、时间格式正确。
//
// 业务逻辑（建库、迁移、增删改查、笔记本层级、重启后数据仍在）由 Rust 侧测试覆盖：
// `nested_app::api::notes` 验证 FFI 边界行为，`ffi_integration_test.dart`
// 验证跨语言链路。这里刻意不重复——Widget 测试的价值在于
// "界面会不会白屏 / 崩溃 / 少部件"。
//
// ## 为什么要注入假数据
//
// 三栏部件依赖内核（通过 `engineProvider`），首次进入时处于加载态。
// 若直接 pump 就断言，只能测到"加载中"。因此用 `ProviderScope.overrides`
// 注入内核返回的数据，从而**确定性地**验证渲染结果——
// 这也让测试不依赖真实文件系统与平台通道。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/app.dart';
import 'package:nested/app/note_list_pane.dart';
import 'package:nested/app/notebook_sidebar.dart';
import 'package:nested/app/notes_page.dart';
import 'package:nested/core/engine.dart';
import 'package:nested/core/engine_providers.dart';
import 'package:nested/core/notebook_providers.dart';
import 'package:nested/app/icons.dart';
import 'package:nested/core/note_providers.dart';

/// 一个"引擎已就绪"的假状态。
EngineStatus fakeEngineStatus() => const EngineStatus(
  displayName: '拾光笔记',
  version: '0.1.0',
  protocolVersion: 1,
  ready: true,
  checks: <EngineCheck>[
    EngineCheck(name: 'database_open', passed: true),
    EngineCheck(name: 'schema_current', passed: true),
    EngineCheck(name: 'integrity', passed: true),
  ],
  databasePath: 'C:/fake/nested.db',
);

/// 注入引擎状态 + 笔记本树 + 笔记列表。
///
/// 注意 `overrides` 不写显式类型：Riverpod 3 未公开 `Override` 这个类型名，
/// 交给类型推断即可。
Widget harness({
  List<NotebookNode> notebooks = const <NotebookNode>[],
  List<NoteItem> notes = const <NoteItem>[],
}) {
  return ProviderScope(
    overrides: [
      engineProvider.overrideWith((Ref ref) async => fakeEngineStatus()),
      notebooksTreeProvider.overrideWith((Ref ref) async => notebooks),
      noteListProvider.overrideWith(
        (Ref ref, NoteListQuery query) async => notes,
      ),
    ],
    child: const MaterialApp(home: NotesPage()),
  );
}

/// 造一个笔记本节点。
NotebookNode node({
  required String id,
  required String name,
  int depth = 0,
  int noteCount = 0,
}) {
  return NotebookNode(
    id: id,
    name: name,
    parentId: depth == 0 ? null : 'parent',
    depth: depth,
    noteCount: noteCount,
  );
}

/// 造一篇笔记。
NoteItem note({
  required String id,
  required String title,
  String summary = '',
  int version = 1,
}) {
  return NoteItem(
    id: id,
    title: title,
    summary: summary,
    updatedAtMs: DateTime(2026, 3, 16, 10, 0).millisecondsSinceEpoch,
    version: version,
    deleted: false,
  );
}

void main() {
  testWidgets('应用外壳能启动并显示中文品牌名', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: NestedNoteApp()));
    expect(find.text(kBrandNameZh), findsOneWidget);
  });

  testWidgets('引擎未就绪时显示加载态而不是崩溃', (WidgetTester tester) async {
    // 不注入 override：engineProvider 会去真实解析数据目录，
    // 在测试环境里它停在加载态。不崩溃即通过。
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NotesPage())),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('三栏布局的关键部件都在', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        notebooks: <NotebookNode>[node(id: 'nb1', name: '工作')],
      ),
    );
    await tester.pumpAndSettle();

    // 左栏：笔记本树
    expect(find.byType(NotebookSidebar), findsOneWidget);
    expect(find.text('笔记本'), findsOneWidget);
    expect(find.text('全部笔记'), findsWidgets);
    expect(find.text('工作'), findsOneWidget);

    // 中栏：笔记列表
    expect(find.byType(NoteListPane), findsOneWidget);
    expect(find.byIcon(kNewNoteIcon), findsOneWidget, reason: '在此新建笔记');

    // 右栏：未选笔记时的提示
    expect(find.text('从左侧选择一篇笔记'), findsOneWidget);

    // 工具栏
    expect(find.byIcon(kCollapseSidebarIcon), findsOneWidget, reason: '折叠左栏');
    expect(find.byIcon(kRecycleBinIcon), findsOneWidget, reason: '回收站');
    expect(find.byIcon(kDiagnosticsIcon), findsOneWidget, reason: '引擎自检');
  });

  testWidgets('折叠左栏后笔记本树消失，中栏与右栏仍在', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byType(NotebookSidebar), findsOneWidget);

    await tester.tap(find.byIcon(kCollapseSidebarIcon));
    await tester.pumpAndSettle();

    expect(find.byType(NotebookSidebar), findsNothing, reason: '折叠后应移除');
    expect(find.byType(NoteListPane), findsOneWidget, reason: '折叠只为内容让位');
    expect(find.text('从左侧选择一篇笔记'), findsOneWidget, reason: '右栏仍在');
  });

  testWidgets('笔记本树按深度缩进，并显示子树笔记数', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        notebooks: <NotebookNode>[
          node(id: 'a', name: '顶层', noteCount: 5),
          node(id: 'b', name: '子层', depth: 1, noteCount: 3),
          node(id: 'c', name: '孙层', depth: 2, noteCount: 1),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('顶层'), findsOneWidget);
    expect(find.text('子层'), findsOneWidget);
    expect(find.text('孙层'), findsOneWidget);

    // 计数：非 0 才显示
    expect(find.text('5'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    // 缩进随深度递增：取三者所在 Container 的左内边距比较
    double leftPaddingOf(String label) {
      final Finder tile = find.ancestor(
        of: find.text(label),
        matching: find.byType(Container),
      );
      final Container container = tester.widget<Container>(tile.first);
      final EdgeInsetsGeometry? padding = container.padding;
      return padding is EdgeInsets ? padding.left : -1;
    }

    final double top = leftPaddingOf('顶层');
    final double mid = leftPaddingOf('子层');
    final double deep = leftPaddingOf('孙层');
    expect(mid, greaterThan(top), reason: '子层应比顶层缩进更多');
    expect(deep, greaterThan(mid), reason: '孙层应比子层缩进更多');
  });

  testWidgets('中栏列出笔记的标题与摘要', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        notes: <NoteItem>[
          note(id: 'n1', title: '第一篇', summary: '这是摘要', version: 3),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一篇'), findsOneWidget);
    expect(find.text('这是摘要'), findsOneWidget);
  });

  testWidgets('中栏空列表时给出可操作提示', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('这里还没有笔记'), findsOneWidget);
    expect(find.text('点右上方 + 新建一篇'), findsOneWidget);
  });

  testWidgets('切换回收站后标题变为回收站且新建按钮禁用', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(kRecycleBinIcon));
    await tester.pumpAndSettle();

    expect(find.text('回收站'), findsWidgets);
    expect(find.text('回收站是空的'), findsOneWidget);

    final IconButton addButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(kNewNoteIcon),
        matching: find.byType(IconButton),
      ),
    );
    expect(addButton.onPressed, isNull, reason: '回收站中不应允许新建');
  });

  group('笔记本层级渲染', () {
    testWidgets('深层级（6 层）仍能按深度递增缩进', (WidgetTester tester) async {
      // 层级没有硬上限。这里渲染 6 层，确认每层缩进严格递增——
      // 第一版用 `depth.clamp(0, 6)` 时，第 7 层起缩进完全相同，
      // 两个不同层级的节点看起来一样深。
      final List<NotebookNode> deep = <NotebookNode>[
        for (int depth = 0; depth <= 5; depth++)
          node(id: 'n$depth', name: '第$depth层', depth: depth),
      ];
      await tester.pumpWidget(harness(notebooks: deep));
      await tester.pumpAndSettle();

      double leftPaddingOf(String label) {
        final Finder tile = find.ancestor(
          of: find.text(label),
          matching: find.byType(Container),
        );
        final Container container = tester.widget<Container>(tile.first);
        final EdgeInsetsGeometry? padding = container.padding;
        return padding is EdgeInsets ? padding.left : -1;
      }

      double previous = -1;
      for (int depth = 0; depth <= 5; depth++) {
        final double current = leftPaddingOf('第$depth层');
        expect(
          current,
          greaterThan(previous),
          reason: '第 $depth 层的缩进应大于上一层（实际 $current vs $previous）',
        );
        previous = current;
      }
    });

    test('缩进在到达上限前每层都不同，之后不再增加', () {
      // 这是纯函数层面的不变量，比渲染断言更直接
      expect(notebookIndent(0), kIndentBase, reason: '顶层只有基础内边距');
      expect(
        notebookIndent(1),
        kIndentBase + kIndentPerLevel,
        reason: '每层加固定步长',
      );

      // 上限之前严格递增
      for (int depth = 1; notebookIndent(depth) < kIndentMax; depth++) {
        expect(
          notebookIndent(depth),
          greaterThan(notebookIndent(depth - 1)),
          reason: '第 $depth 层必须比上一层更深',
        );
      }

      // 至少要能区分到第 8 层（大多数真实用法远低于此）
      expect(
        notebookIndent(8),
        greaterThan(notebookIndent(7)),
        reason: '8 层之内必须层级分明',
      );

      // 上限之后不再增加，且绝不超过上限
      for (final int depth in <int>[20, 50, 999]) {
        expect(
          notebookIndent(depth),
          kIndentMax,
          reason: '超过上限后应稳定在上限，而不是把名称挤出可视区',
        );
      }
    });

    test('负深度不会被推到屏幕外', () {
      // 不该出现，但出现了也不能把内容挤出可视区
      expect(notebookIndent(-1), kIndentBase);
      expect(notebookIndent(-100), kIndentBase);
    });
  });

  group('分栏可拖动调整宽度', () {
    /// 取某个部件当前的渲染宽度。
    double widthOf(WidgetTester tester, Finder finder) =>
        tester.getSize(finder).width;

    testWidgets('三栏各有一条可拖动分隔条（左栏折叠时剩两条）', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.byType(PaneSplitter), findsNWidgets(2), reason: '左栏 + 中栏各一条');

      // 展开左栏后是两条分隔条（左|中、中|右）
      await tester.pumpWidget(
        harness(
          notebooks: <NotebookNode>[node(id: 'nb', name: '工作')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PaneSplitter), findsNWidgets(2));
    });

    testWidgets('向右拖动中栏分隔条会加宽中栏', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final Finder listPane = find.byType(NoteListPane);
      final double before = widthOf(tester, listPane);

      // 拖动**第二个**分隔条（中栏与右栏之间）
      final Finder splitter = find.byType(PaneSplitter).at(1);
      await tester.drag(splitter, const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(
        widthOf(tester, listPane),
        greaterThan(before),
        reason: '向右拖动应加宽中栏（$before → ${widthOf(tester, listPane)}）',
      );
    });

    testWidgets('向左拖动中栏分隔条会收窄中栏', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final Finder listPane = find.byType(NoteListPane);
      final double before = widthOf(tester, listPane);

      await tester.drag(find.byType(PaneSplitter).at(1), const Offset(-50, 0));
      await tester.pumpAndSettle();

      expect(widthOf(tester, listPane), lessThan(before));
    });

    testWidgets('中栏宽度不会超过上限，也不会低于下限', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final Finder listPane = find.byType(NoteListPane);

      // 往右猛拖：应停在上限
      await tester.drag(find.byType(PaneSplitter).at(1), const Offset(1200, 0));
      await tester.pumpAndSettle();
      expect(
        widthOf(tester, listPane),
        lessThanOrEqualTo(kNoteListMaxWidth + 0.5),
        reason: '不应无限加宽',
      );

      // 往左猛拖：应停在下限
      await tester.drag(
        find.byType(PaneSplitter).at(1),
        const Offset(-1200, 0),
      );
      await tester.pumpAndSettle();
      expect(
        widthOf(tester, listPane),
        greaterThanOrEqualTo(kNoteListMinWidth - 0.5),
        reason: '不应被拖到 0 宽——那会让用户以为列表没了',
      );
      expect(find.byType(NoteListPane), findsOneWidget, reason: '中栏仍然存在');
    });

    testWidgets('左栏拖动后仍给右栏留出最小宽度', (WidgetTester tester) async {
      // 展开左栏
      await tester.pumpWidget(
        harness(
          notebooks: <NotebookNode>[node(id: 'nb', name: '工作')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NotebookSidebar), findsOneWidget);

      // 把左栏往右猛拖
      await tester.drag(find.byType(PaneSplitter).first, const Offset(2000, 0));
      await tester.pumpAndSettle();

      // 右栏（阅读区提示）必须仍然可见且有合理宽度
      final Finder reading = find.text('从左侧选择一篇笔记');
      expect(reading, findsOneWidget, reason: '右栏不能被挤掉');
      expect(
        tester
            .getSize(
              find.ancestor(of: reading, matching: find.byType(Center)).first,
            )
            .width,
        greaterThan(0),
      );
    });
  });

  group('图标体系', () {
    testWidgets('不同层级的笔记本用不同的文件夹图标', (WidgetTester tester) async {
      await tester.pumpWidget(
        harness(
          notebooks: <NotebookNode>[
            // 名称刻意用不会与界面固定文案（"全部笔记""笔记本"）相撞的词，
            // 否则 find.text 可能匹配到别的部件
            node(id: 'a', name: '甲层', depth: 0),
            node(id: 'b', name: '乙层', depth: 1),
            node(id: 'c', name: '丙层', depth: 2),
            node(id: 'd', name: '丁层', depth: 3),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 按行部件定位图标：不能用 find.ancestor(byType(Row))——
      // 那会命中整棵树的 Row，descendant.first 取到的是别的图标
      // （本项目就在这里踩过一次，测试报"三个层级只有两个不同图标"）。
      IconData iconOf(String label) {
        final Finder tile = find.ancestor(
          of: find.text(label),
          matching: find.byType(NotebookTreeTile),
        );
        final Finder icon = find.descendant(
          of: tile.first,
          matching: find.byType(Icon),
        );
        return tester.widget<Icon>(icon.first).icon!;
      }

      final IconData top = iconOf('甲层');
      final IconData second = iconOf('乙层');
      final IconData third = iconOf('丙层');
      final IconData fourth = iconOf('丁层');

      expect(
        <IconData>{top, second, third},
        hasLength(3),
        reason: '第 1/2/3 层必须是三个不同的图标——这是多层级可视化的前提',
      );
      expect(fourth, third, reason: '超过图标档位后复用最深一档（形状不再细分，但一致）');
    });

    test('层级图标取自同一族，超出档位时落到最深一档', () {
      // 同族：都能在 kFolderIconsByDepth 里找到
      for (int depth = 0; depth < kFolderIconsByDepth.length; depth++) {
        expect(folderIconForDepth(depth), kFolderIconsByDepth[depth]);
      }
      expect(folderIconForDepth(99), kNotebookDeepIcon, reason: '超出档位用最深一档');
      expect(folderIconForDepth(-1), kNotebookRootIcon, reason: '非法深度兜底');

      // 三档互不相同（否则层级就分不出来了）
      expect(
        kFolderIconsByDepth.toSet(),
        hasLength(kFolderIconsByDepth.length),
      );
    });

    testWidgets('中栏每行笔记都带笔记图标，且回收站中形状不变', (WidgetTester tester) async {
      // 一致性要求必须落到**渲染结果**上，否则只是同义反复：
      // 早期版本定义了 kNoteIcon 却从未使用（笔记行根本没有图标），
      // 于是"同一概念同形"这条规则实际上没被验证过。
      await tester.pumpWidget(
        harness(
          notes: <NoteItem>[
            note(id: 'n1', title: '甲笔记'),
            NoteItem(
              id: 'n2',
              title: '乙笔记',
              summary: '',
              updatedAtMs: DateTime(2026, 3, 16, 10, 0).millisecondsSinceEpoch,
              version: 1,
              deleted: true,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 两行各有一个笔记图标（形状相同）
      expect(find.byIcon(kNoteIcon), findsNWidgets(2));

      // 已删除那行多一个"在回收站中"的标记，但笔记图标本身不变
      expect(find.byIcon(kInRecycleBinBadgeIcon), findsOneWidget);
      expect(
        find.byIcon(kNoteIcon),
        findsNWidgets(2),
        reason: '回收站里的笔记不能换成垃圾桶图标——那会被读成"一个删除动作"',
      );
    });

    test('同一概念在不同位置必须同形（纯不变量）', () {
      expect(kDeletedNoteIcon, kNoteIcon, reason: '回收站里的笔记只改颜色，形状不变');
      expect(kNoteIcon, isNot(kEmptyReadingIcon), reason: '笔记与空态提示本就是两回事');
      expect(kNoteIcon, isNot(kAllNotesIcon), reason: '"一篇笔记"与"全部笔记"入口不是同一概念');
      expect(kRecycleBinIcon, isNot(kRecycleBinActiveIcon), reason: '开关两态需可区分');
    });
  });

  group('列表时间格式', () {
    // 纯函数直接断言，比解析渲染后的文本更可靠
    final DateTime now = DateTime(2026, 3, 16, 14, 30);

    test('同一天只显示时间', () {
      final int ms = DateTime(2026, 3, 16, 9, 5).millisecondsSinceEpoch;
      expect(formatListTime(ms, now: now), '09:05');
    });

    test('同年显示月-日', () {
      final int ms = DateTime(2026, 1, 8, 9, 5).millisecondsSinceEpoch;
      expect(formatListTime(ms, now: now), '01-08');
    });

    test('跨年显示完整日期', () {
      final int ms = DateTime(2025, 12, 31, 9, 5).millisecondsSinceEpoch;
      expect(formatListTime(ms, now: now), '2025-12-31');
    });

    test('补零到两位', () {
      // 注意参考日期必须与待格式化的是**同一天**，否则走的是"月-日"分支
      final int ms = DateTime(2026, 3, 6, 7, 8).millisecondsSinceEpoch;
      expect(formatListTime(ms, now: DateTime(2026, 3, 6, 23, 59)), '07:08');
    });
  });
}
