// SPDX-License-Identifier: AGPL-3.0-or-later
//! 应用外壳：主题与首页。
//!
//! 首页是**笔记列表**（`notes_page.dart`）——P1 的最小可用闭环：
//! 新建 → 列表 → 编辑 → 保存 → 重启后仍在。
//!
//! 引擎自检页在 P0 作为验收界面，现在降级为列表页工具栏里的一个入口：
//! 它仍然有用（排查"动态库没加载 / 目录不可写"），但不再是用户看到的第一屏。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notes_page.dart';

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
    // 品牌色：低饱和的墨绿，长时间阅读不刺眼
    const Color seed = Color(0xFF3F6B5C);

    return MaterialApp(
      title: kBrandNameZh,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // 深色模式跟随系统（铁律 F8：必须支持深色模式）
      themeMode: ThemeMode.system,
      home: const NotesPage(),
    );
  }
}
