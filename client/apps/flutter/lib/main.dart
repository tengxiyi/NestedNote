// SPDX-License-Identifier: AGPL-3.0-or-later
//! 拾光笔记 / NestedNote —— Flutter 应用入口。
//!
//! 分层约定（《工程铁律》A1/A2/F1）：
//!
//! ```text
//! lib/app        应用启动、主题、路由
//! lib/core       引擎封装（**唯一**允许调用 Rust FFI 的位置）、平台适配、错误映射
//! lib/src/rust   flutter_rust_bridge 生成的绑定（不入库，仅 lib/core 可 import）
//! lib/features   业务页面（禁止直接接触 FFI）
//! lib/editor     编辑器与 Document Model Adapter
//! lib/search     搜索
//! lib/settings   设置
//! lib/sync       同步状态与冲突 UI
//! ```
//!
//! **禁止**在本层（或任何 Dart 代码）直接访问 SQLite、文件数据库或实现业务规则：
//! 所有事实来自 Rust 内核（铁律 T4）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  runApp(const ProviderScope(child: NestedNoteApp()));
}
