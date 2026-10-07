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
import 'package:nested/app/notes_page.dart';
import 'package:nested/core/engine.dart';
import 'package:nested/core/engine_providers.dart';
import 'package:nested/core/notebook_providers.dart';
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
    expect(find.byIcon(Icons.add), findsOneWidget, reason: '在此新建笔记');

    // 右栏：未选笔记时的提示
    expect(find.text('从左侧选择一篇笔记'), findsOneWidget);

    // 工具栏
    expect(find.byIcon(Icons.menu_open), findsOneWidget, reason: '折叠左栏');
    expect(find.byIcon(Icons.delete_outlined), findsOneWidget, reason: '回收站');
    expect(
      find.byIcon(Icons.monitor_heart_outlined),
      findsOneWidget,
      reason: '引擎自检',
    );
  });

  testWidgets('折叠左栏后笔记本树消失，中栏与右栏仍在', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byType(NotebookSidebar), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_open));
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

    await tester.tap(find.byIcon(Icons.delete_outlined));
    await tester.pumpAndSettle();

    expect(find.text('回收站'), findsWidgets);
    expect(find.text('回收站是空的'), findsOneWidget);

    final IconButton addButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.add),
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
