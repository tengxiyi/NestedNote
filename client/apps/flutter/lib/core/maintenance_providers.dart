// SPDX-License-Identifier: AGPL-3.0-or-later
//! 维护操作的数据层：包装 Rust 绑定，供界面层使用。
//!
//! ## 为什么存在
//!
//! 铁律 A-LAYERING：界面不得直接 import Rust 生成绑定。设置对话框
//! 第一版直接 import 了 `api/maintenance.dart`，被规则检查器拦下。
//! 与 `attachment_providers.dart` 同一个理由、同一个手法。
//!
//! 只做转发，不加业务规则（铁律 T4：规则在内核里）。

import '../src/rust/api/maintenance.dart' as rust;

export '../src/rust/api/maintenance.dart' show ActivityEntry, MaintenanceResult;

/// 运行附件清理。
///
/// `atMs` 由界面传入：宽限期判断的时间权威来源只有一个（Dart 的时钟），
/// 判断错了会**误删用户的附件**，这里比别处更输不起。
Future<rust.MaintenanceResult> gcAttachments(int atMs) =>
    rust.maintenanceGcAttachments(atMs: atMs);

/// 核对数据库完整性（只读，失败不会让情况变得更糟）。
Future<rust.MaintenanceResult> checkIntegrity() =>
    rust.maintenanceCheckIntegrity();

/// 最近的活动记录（时间倒序）。
///
/// `limit = 0` 由内核解释为"给一个合理的默认值"。
Future<List<rust.ActivityEntry>> listActivity(int limit) =>
    rust.activityRecent(limit: limit);
