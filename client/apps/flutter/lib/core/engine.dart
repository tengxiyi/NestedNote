// SPDX-License-Identifier: AGPL-3.0-or-later
//! 引擎封装的公共类型。
//!
//! 本文件**不**导入 FFI，只定义纯 Dart 数据结构，
//! 这样 UI 与测试都不依赖绑定是否已生成。

/// 单条自检项。
class EngineCheck {
  /// 构造自检项。
  const EngineCheck({required this.name, required this.passed});

  /// 检查名称。
  final String name;

  /// 是否通过。
  final bool passed;
}

/// 引擎状态。
class EngineStatus {
  /// 构造状态。
  const EngineStatus({
    required this.displayName,
    required this.version,
    required this.protocolVersion,
    required this.ready,
    required this.checks,
    this.databasePath,
    this.message,
  });

  /// 界面显示名（由 Rust 侧按语言返回，**禁止**在 Dart 里硬编码品牌名）。
  final String displayName;

  /// 内核版本。
  final String version;

  /// 同步协议版本。
  final int protocolVersion;

  /// 是否全部就绪。
  final bool ready;

  /// 逐项自检结果。
  final List<EngineCheck> checks;

  /// 数据库文件的绝对路径（自检成功时由 Rust 侧返回）。
  final String? databasePath;

  /// 失败时的可读信息（**不含**内部细节）。
  final String? message;
}
