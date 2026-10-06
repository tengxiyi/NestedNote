//! 应用外壳：主题与首页。
//!
//! 说明：P0 的首页刻意只显示"引擎自检结果"，它是 P0 的验收界面
//! （开发计划 P0-5：从 Dart 调通 Rust）。三栏桌面 UI 属于 P3。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine.dart';
import '../core/engine_providers.dart';

/// 品牌中文名（与 Rust 侧 `nested_core::branding` 保持一致）。
///
/// 说明：引擎启动成功后，显示名会从 Rust 侧读取；
/// 这里的常量仅用于"引擎尚未就绪时"的首屏占位。
const String kBrandNameZh = '拾光笔记';

/// 应用根组件。
class NestedNoteApp extends ConsumerWidget {
  /// 构造应用。
  const NestedNoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: kBrandNameZh,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F6B5C)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F6B5C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // 深色模式跟随系统（铁律 F8：必须支持深色模式）
      themeMode: ThemeMode.system,
      home: const EngineStatusPage(),
    );
  }
}

/// 引擎自检页：P0 的验收界面。
class EngineStatusPage extends ConsumerWidget {
  /// 构造页面。
  const EngineStatusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(kBrandNameZh),
        actions: <Widget>[
          IconButton(
            tooltip: '重新自检',
            onPressed: () => ref.invalidate(engineProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (engine) {
              // 注意：AsyncValue 的 data 载荷字段名是 `value`，不是 `status`。
              AsyncData(:final EngineStatus value) => _StatusView(
                status: value,
                theme: theme,
              ),
              AsyncError(:final Object error) => _ErrorView(
                message: '$error',
                theme: theme,
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ),
      ),
    );
  }
}

/// 自检结果视图。
class _StatusView extends StatelessWidget {
  const _StatusView({required this.status, required this.theme});

  final EngineStatus status;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final okCount = status.checks.where((EngineCheck c) => c.passed).length;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(status.displayName, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          '内核版本 ${status.version}　·　协议 v${status.protocolVersion}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '启动自检（$okCount/${status.checks.length} 通过）',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                for (final EngineCheck check in status.checks)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      check.passed ? Icons.check_circle : Icons.error,
                      color: check.passed
                          ? Colors.green
                          : theme.colorScheme.error,
                    ),
                    title: Text(check.name),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          status.ready ? '引擎就绪，P0 最小闭环已打通。' : '引擎未就绪，请检查上方失败项。',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// 错误视图（**不**显示堆栈，铁律 E2）。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.theme});

  final String message;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 16),
        Text('引擎启动失败', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}
