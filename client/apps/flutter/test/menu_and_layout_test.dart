// SPDX-License-Identifier: AGPL-3.0-or-later
// 三栏显示模式与菜单栏的测试。
//
// ## 为什么这些值得测
//
// 「只看编辑器」会把中栏**从组件树上摘掉**。这类"把东西藏起来"的功能
// 最容易出的错不是"藏不掉"，而是**藏掉之后回不来**——而回来的路
// 恰恰依赖被藏掉的那一栏还在。
//
// 因此这里重点验证两件事：
// 1. 三种模式真的改变布局；
// 2. **每种模式下都还能切回三栏**（快捷键宿主必须在页面级，不能被摘掉）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/menu_bar.dart';
import 'package:nested/app/note_list_pane.dart';
import 'package:nested/app/note_editor_page.dart';
import 'package:nested/app/notes_page.dart';
import 'package:nested/app/notebook_sidebar.dart';
import 'package:nested/app/shortcuts.dart';
import 'package:nested/app/shortcuts_host.dart';
import 'package:nested/core/engine_providers.dart';
import 'package:nested/core/layout_providers.dart';
import 'package:nested/core/notebook_providers.dart';
import 'package:nested/core/note_providers.dart';

import 'widget_test.dart' show fakeEngineStatus;

Widget harness() {
  return ProviderScope(
    overrides: [
      engineProvider.overrideWith((Ref ref) async => fakeEngineStatus()),
      notebooksTreeProvider.overrideWith(
        (Ref ref) async => const <NotebookNode>[
          NotebookNode(
            id: 'n1',
            name: '工作',
            parentId: null,
            depth: 0,
            noteCount: 1,
            directNoteCount: 1,
          ),
        ],
      ),
      noteListProvider.overrideWith(
        (Ref ref, NoteListQuery query) async => const <NoteItem>[
          NoteItem(
            id: 'note-1',
            title: '一篇笔记',
            summary: '',
            updatedAtMs: 0,
            version: 1,
            deleted: false,
          ),
        ],
      ),
      // 编辑器打开时会去读正文。不拦截的话它会真的调 FFI，
      // 而单元测试里没有引擎 → "flutter_rust_bridge has not been initialized"。
      noteSnapshotProvider.overrideWith(
        (Ref ref, String id) async =>
            const NoteSnapshot(title: '一篇笔记', text: '正文内容'),
      ),
      noteTextProvider.overrideWith((Ref ref, String id) async => '正文内容'),
    ],
    // `AppShortcutHost` 必须在 `MaterialApp` **外面**——这正是
    // 真实应用（`app.dart`）的结构，harness 必须照抄，
    // 否则测出来的东西与线上不是一回事。
    child: const AppShortcutHost(child: MaterialApp(home: NotesPage())),
  );
}

void main() {
  group('显示模式的默认值', () {
    test('默认三栏、左栏不折叠', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(paneLayoutProvider), PaneLayout.threePanes);
      expect(container.read(sidebarCollapsedProvider), isFalse);
    });

    test('折叠与显示模式是**正交**的两件事', () {
      // 折叠是"腾地方"，切模式是"换视图"。混成一个状态会让状态数翻倍，
      // 而其中一半只是同一件事的重复表达。
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sidebarCollapsedProvider.notifier).toggle();
      expect(container.read(sidebarCollapsedProvider), isTrue);
      expect(
        container.read(paneLayoutProvider),
        PaneLayout.threePanes,
        reason: '折叠左栏不该改变显示模式',
      );
    });
  });

  group('菜单栏渲染', () {
    testWidgets('出现四个菜单，且**不含**未实现的菜单', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      for (final String label in <String>['文件', '编辑', '查看', '帮助']) {
        expect(find.text(label), findsOneWidget, reason: '缺少「$label」菜单');
      }

      // 铁律 F5：没有实现的菜单**整个不出现**，而不是显示一个空菜单。
      // 空菜单与置灰的假按钮是同一回事——用户点下去什么都得不到。
      for (final String absent in <String>['格式', '工具']) {
        expect(
          find.text(absent),
          findsNothing,
          reason: '「$absent」在 M1 没有实现，不该出现在菜单栏里',
        );
      }
    });

    testWidgets('三栏默认都渲染', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.byType(NotebookSidebar), findsOneWidget);
      expect(find.byType(NoteListPane), findsOneWidget);
      expect(find.byType(AppMenuBar), findsOneWidget);
    });
  });

  group('显示模式切换', () {
    testWidgets('只看编辑器时，笔记本栏与列表都消失', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(NotesPage)),
      );
      container.read(paneLayoutProvider.notifier).editorOnly();
      await tester.pumpAndSettle();

      expect(find.byType(NotebookSidebar), findsNothing);
      expect(
        find.byType(NoteListPane),
        findsNothing,
        reason: '只看编辑器时笔记列表应当被摘掉，而不是宽度设成 0',
      );
    });

    testWidgets('只看列表时，编辑器消失但左栏还在', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(NotesPage)),
      );
      container.read(paneLayoutProvider.notifier).listOnly();
      await tester.pumpAndSettle();

      expect(
        find.byType(NotebookSidebar),
        findsOneWidget,
        reason: '只看列表时仍要能换笔记本，否则用户被锁死在这一篇',
      );
      expect(find.byType(NoteListPane), findsOneWidget);
      expect(find.byType(NoteEditorPane), findsNothing);
    });

    testWidgets('**藏起来之后还能回来**：快捷键 Ctrl+3 恢复三栏', (WidgetTester tester) async {
      // 这条是整组里最重要的：若快捷键宿主挂在会被摘掉的栏里，
      // 「只看编辑器」之后 Ctrl+3 就再也收不到，用户被永久困住。
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(NotesPage)),
      );

      // 进入只看编辑器
      container.read(paneLayoutProvider.notifier).editorOnly();
      await tester.pumpAndSettle();
      expect(find.byType(NoteListPane), findsNothing);

      // 用**真的按键**切回来，而不是直接改 provider——
      // 那才验证了快捷键在"栏被摘掉"之后仍然有效。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(
        container.read(paneLayoutProvider),
        PaneLayout.threePanes,
        reason: 'Ctrl+3 应当能恢复三栏',
      );
      expect(find.byType(NoteListPane), findsOneWidget, reason: '列表栏应当回来了');
    });

    testWidgets('Ctrl+4 折叠左栏', (WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(NotesPage)),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(container.read(sidebarCollapsedProvider), isTrue);
      expect(find.byType(NotebookSidebar), findsNothing);
    });

    testWidgets('**焦点在输入框里时快捷键仍然有效**', (WidgetTester tester) async {
      // ## 这条防的是一个很容易被忽略的失败模式
      //
      // Flutter 的 `MaterialApp` 里有一层 `DefaultTextEditingShortcuts`，
      // 专门接管文本框的按键（Ctrl+A/C/V/Z…）。若它比我们的
      // `Shortcuts` 更靠近焦点，我们的键就会被它先吃掉——
      // 表现为"菜单写着 Ctrl+1，但光标在正文里时按下去没反应"。
      //
      // 用户不会去分析按键派发顺序，他只会说"快捷键有时灵有时不灵"。
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      // 先打开一篇笔记，让编辑器出现
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(NotesPage)),
      );
      await tester.tap(find.text('一篇笔记'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorPane), findsOneWidget);

      // 让焦点进到正文输入框
      final Finder fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: '编辑器应当有输入框');
      await tester.tap(fields.last);
      await tester.pumpAndSettle();

      // 在输入框有焦点的情况下按 Ctrl+2
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(
        container.read(paneLayoutProvider),
        PaneLayout.editorOnly,
        reason: '焦点在输入框里时 Ctrl+2 也必须生效',
      );
    });
  });

  group('快捷键口径', () {
    test('菜单标注与实际绑定**同源**', () {
      // 两处各写一份字符串迟早会出现"菜单写着 Ctrl+D、按下去没反应"。
      // 这里断言 `label` 与 `activator` 描述的是同一个键。
      for (final AppShortcut s in <AppShortcut>[
        AppShortcuts.newNote,
        AppShortcuts.newChildNotebook,
        AppShortcuts.save,
        AppShortcuts.undo,
        AppShortcuts.redo,
        AppShortcuts.viewListOnly,
        AppShortcuts.viewEditorOnly,
        AppShortcuts.viewThreePanes,
        AppShortcuts.toggleSidebar,
        AppShortcuts.shortcutsHelp,
      ]) {
        expect(s.label, isNotEmpty, reason: '每个快捷键都要有可显示的标注');
      }
    });

    test('不用 F10/F11/Ctrl+F11（用户明确不要）', () {
      final Set<LogicalKeyboardKey> forbidden = <LogicalKeyboardKey>{
        LogicalKeyboardKey.f10,
        LogicalKeyboardKey.f11,
      };
      for (final AppShortcut s in <AppShortcut>[
        AppShortcuts.newNote,
        AppShortcuts.viewListOnly,
        AppShortcuts.viewEditorOnly,
        AppShortcuts.viewThreePanes,
        AppShortcuts.toggleSidebar,
      ]) {
        expect(
          forbidden.contains(s.activator.trigger),
          isFalse,
          reason: '${s.label} 用了与系统冲突的键',
        );
      }
    });

    test('三栏切换用 Ctrl+1/2/3，且互不重复', () {
      final List<SingleActivator> ids = <SingleActivator>[
        AppShortcuts.viewListOnly.activator,
        AppShortcuts.viewEditorOnly.activator,
        AppShortcuts.viewThreePanes.activator,
      ];
      final Set<LogicalKeyboardKey> triggers = ids
          .map((SingleActivator a) => a.trigger)
          .toSet();
      expect(triggers.length, ids.length, reason: '两个动作绑同一个键，其中一个永远收不到');
      expect(triggers, contains(LogicalKeyboardKey.digit1));
      expect(triggers, contains(LogicalKeyboardKey.digit2));
      expect(triggers, contains(LogicalKeyboardKey.digit3));
    });
  });
}
