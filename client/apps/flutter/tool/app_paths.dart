// SPDX-License-Identifier: AGPL-3.0-or-later
// 命令行工具用的数据目录解析 —— **必须与 path_provider 的结果一致**。
//!
//! ## 为什么单独抽出来
//!
//! 应用运行时用 `getApplicationSupportDirectory()` 拿数据目录，而工具脚本
//! （`seed_demo_notes`、`list_notes`、`verify_app`）在纯 Dart 环境下拿不到
//! 平台通道。若两边的路径推导逻辑各写一份，就会出现"脚本写进 A 目录、
//! 应用从 B 目录读"的假故障——本项目已经踩过一次，而且原因更隐蔽：
//!
//! Windows 上 `getApplicationSupportDirectory()` 返回
//! `%APPDATA%\<CompanyName>\<ProductName>`，这两个值来自**可执行文件的版本资源**
//! （`windows/runner/Runner.rc`）。也就是说，改一个 `.rc` 字段就会移动用户数据目录。
//!
//! 因此这里把规则写死并在注释里标明来源，任何一处改动都要同步两边。

import 'dart:io';

/// Windows 上 `getApplicationSupportDirectory()` 的等价路径。
///
/// 对应 `Runner.rc` 中的 `CompanyName = "NestedNote"`、
/// `ProductName = "NestedNote"`。
///
/// 这两个值刻意保持**纯 ASCII**：它们会进入文件系统路径，
/// 中文会给日志、备份脚本与跨平台迁移带来编码麻烦。
Directory resolveAppDataDirForTools() {
  final String appData = Platform.environment['APPDATA'] ?? '';
  if (appData.isEmpty) {
    stderr.writeln('找不到 APPDATA：这些工具目前只支持 Windows。');
    stderr.writeln('其它平台请用 flutter run 或测试里的临时目录。');
    exit(2);
  }
  return Directory('$appData\\NestedNote\\NestedNote');
}
