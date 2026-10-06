// Flutter 侧冒烟测试。
//
// 说明：这是 P0 阶段的最小验证 —— 确认应用外壳能启动、品牌名正确、
// 自检页在"数据未就绪"时显示加载态而不是崩溃。
//
// 完整的引擎自检（真实建库、迁移、完整性校验）在 Rust 侧已有 147 个测试覆盖，
// 这里刻意不去重复它：Widget 测试的价值在于 UI 装配与状态渲染，不在于重跑内核逻辑。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/app.dart';

void main() {
  testWidgets('应用外壳能启动并显示中文品牌名', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: EngineStatusPage())),
    );

    // 首帧：自检数据尚未就绪，应显示加载指示器而不是错误
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(kBrandNameZh), findsOneWidget);
  });

  testWidgets('刷新按钮存在且可点击', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: EngineStatusPage())),
    );

    final refresh = find.byIcon(Icons.refresh);
    expect(refresh, findsOneWidget);

    // 点击不应抛异常（它会 invalidate 引擎状态并触发重新自检）
    await tester.tap(refresh);
    await tester.pump();
  });
}
