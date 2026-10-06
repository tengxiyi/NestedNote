//! 引擎提供者（Riverpod）——**唯一**允许调用 Rust FFI 的位置。
//!
//! 《工程铁律》A2/F1：UI 层不得直接接触存储与业务规则。
//! 所有页面通过 `engineProvider` 间接获得数据。
//!
//! ## 当前状态（P0）
//!
//! Rust 绑定（flutter_rust_bridge 生成）尚未接入，因此这里走 **stub 实现**：
//! 它只报告"FFI 未接入"，**不会**伪造数据（铁律 E6：禁止假成功）。
//!
//! ## P0-5 接入步骤
//!
//! 1. `dart run flutter_rust_bridge_codegen generate`
//! 2. 把 `nested_app_bridge.start_engine(dataDir)` 的返回值换成真实结果；
//! 3. 删除本文件中的 stub 分支。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'engine.dart';

/// 引擎状态提供者。
final FutureProvider<EngineStatus> engineProvider = FutureProvider<EngineStatus>((Ref ref) async {
  return loadEngineStatus();
});

/// 加载引擎状态。
///
/// 这是与 Rust 内核的唯一接触点。绑定接入后，本函数内部改为调用生成的
/// `start_engine`，签名与返回类型保持不变，因此 UI 无需改动。
Future<EngineStatus> loadEngineStatus() async {
  // 解析数据目录：与 Rust 侧 branding::BRAND_SLUG 保持一致（NestedNote）
  final directory = await getApplicationSupportDirectory();
  final dataDir = '${directory.path}/NestedNote';

  // TODO(P0-5): 接入 flutter_rust_bridge 生成的绑定后替换以下 stub。
  // 刻意返回"未接入"而不是伪造成功结果 —— 让缺失在界面上直接可见。
  return EngineStatus(
    displayName: '拾光笔记',
    version: '0.1.0',
    protocolVersion: 1,
    ready: false,
    checks: <EngineCheck>[
      const EngineCheck(name: 'database_open', passed: false),
      const EngineCheck(name: 'schema_current', passed: false),
      const EngineCheck(name: 'integrity', passed: false),
      const EngineCheck(name: 'ffi_bridge', passed: false),
    ],
    message: 'Flutter ↔ Rust 绑定尚未生成（P0-5）。数据目录：$dataDir',
  );
}
