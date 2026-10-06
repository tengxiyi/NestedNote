// SPDX-License-Identifier: AGPL-3.0-or-later
// Flutter 侧冒烟测试。
//
// 说明：这里只验证**界面装配与状态渲染** —— 应用外壳能启动、品牌名正确、
// 引擎未就绪时显示加载态而不是崩溃。
//
// 完整的业务逻辑（建库、迁移、笔记增删改查、重启后数据仍在）在 Rust 侧有
// 专门测试覆盖，其中 `nested_app::api::notes` 的测试直接验证 FFI 边界行为。
// 这里刻意不重复它们：Widget 测试的价值在于"界面会不会白屏/崩溃"，
// 而不是重跑内核逻辑。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/app.dart';
import 'package:nested/app/notes_page.dart';

void main() {
  testWidgets('应用外壳能启动并显示中文品牌名', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: NestedNoteApp()),
    );

    // 首帧：引擎状态尚未就绪，标题使用占位品牌名，且不崩溃
    expect(find.text(kBrandNameZh), findsOneWidget);
  });

  testWidgets('引擎未就绪时显示加载态而不是错误页', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NotesPage())),
    );

    // 引擎 provider 仍在解析中 → 加载指示器
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('新建笔记按钮存在于首屏', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NotesPage())),
    );

    expect(find.text('新建笔记'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('工具栏提供回收站与自检入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: NotesPage())),
    );

    expect(find.byIcon(Icons.delete_outlined), findsOneWidget);
    expect(find.byIcon(Icons.monitor_heart_outlined), findsOneWidget);
  });
}
