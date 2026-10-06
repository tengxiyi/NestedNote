//! 引擎提供者（Riverpod）——**唯一**允许调用 Rust FFI 的位置。
//!
//! 《工程铁律》A2/F1：UI 层不得直接接触存储与业务规则。
//! 所有页面通过 `engineProvider` 间接获得数据；`lib/src/rust/**` 是生成代码，
//! 除本文件外任何地方都不得 import（否则分层就失效了）。
//!
//! 数据流：
//!
//! ```text
//! UI（EngineStatusPage）
//!   → engineProvider（本文件）
//!     → lib/src/rust（FRB 生成绑定）
//!       → nested_app::api::branding（Rust 手写 API）
//!         → nested-core → nested-db → SQLite
//! ```

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/branding.dart' as rust;
import '../src/rust/frb_generated.dart';
import 'engine.dart';

/// 引擎状态提供者。
final FutureProvider<EngineStatus> engineProvider =
    FutureProvider<EngineStatus>((Ref ref) async {
      return loadEngineStatus();
    });

/// 启动引擎并返回自检结果。
///
/// 这是与 Rust 内核的唯一接触点。步骤：
/// 1. 初始化 FRB 运行时（幂等，重复调用安全）；
/// 2. 解析数据目录（`path_provider`，需要 Flutter binding）；
/// 3. 调用 `startEngine` —— Rust 侧会在该目录建库、执行迁移、校验完整性。
///
/// 测试场景请改用 [startEngineInDirectory]：它不依赖平台通道，
/// 可以传入临时目录，从而在 `flutter test` 里真实跑通 FFI。
Future<EngineStatus> loadEngineStatus() async {
  await RustLib.init();
  return startEngineInDirectory(await resolveDataDir());
}

/// 在指定目录启动引擎（不依赖 `path_provider`，可在测试中调用）。
///
/// 调用前需已完成 [RustLib.init]（[loadEngineStatus] 会代劳）。
///
/// ## 为什么把结果写入诊断文件
///
/// 引擎失败时只会在界面上显示一句可读提示，而排查"到底是动态库没加载成功，
/// 还是目录不可写"需要看到**真实的返回值与异常**。因此这里额外落一份
/// `engine-status.txt` 到系统临时目录：它不影响功能，但让现场问题可被复现。
/// 生产环境若日志系统就绪（P1），这段应改为结构化日志（铁律 E5）。
Future<EngineStatus> startEngineInDirectory(String dataDir) async {
  // 品牌名与版本只有一个来源（Rust 侧 branding 模块，见项目章程 §1.0）。
  final info = await rust.versionInfo();

  // 顺带验证"显示名也来自 Rust"这条契约：语言标签由 Dart 传入，名字由 Rust 决定。
  final localizedName = await rust.displayName(languageTag: 'zh-CN');

  EngineStatus status;
  try {
    final raw = await rust.startEngine(dataDir: dataDir);
    status = EngineStatus(
      displayName: localizedName,
      version: info.version,
      protocolVersion: info.protocolVersion,
      ready: raw.ready,
      checks: raw.checks
          .map(
            (rust.EngineCheck check) =>
                EngineCheck(name: check.name, passed: check.passed),
          )
          .toList(growable: false),
      databasePath: raw.databasePath,
      message: raw.message,
    );
  } catch (error) {
    // FFI 边界本不该抛异常（Rust 侧把失败都转成了结构化结果），
    // 但动态库加载失败等情况仍可能抛出，因此这里兜底而不是让它冒到 UI（铁律 E6）。
    status = EngineStatus(
      displayName: localizedName,
      version: info.version,
      protocolVersion: info.protocolVersion,
      ready: false,
      checks: const <EngineCheck>[],
      message: '无法启动内核：$error',
    );
  }

  await _writeDiagnostics(dataDir, status);
  return status;
}

/// 把一次自检的结果写入临时目录，便于排查"界面只显示一句提示"的现场问题。
Future<void> _writeDiagnostics(String dataDir, EngineStatus status) async {
  try {
    final lines = <String>[
      'dataDir=$dataDir',
      'ready=${status.ready}',
      'displayName=${status.displayName}',
      'version=${status.version}',
      'protocolVersion=${status.protocolVersion}',
      'databasePath=${status.databasePath}',
      'message=${status.message}',
      for (final check in status.checks) 'check ${check.name}=${check.passed}',
    ];
    await File(
      '${Directory.systemTemp.path}/engine-status.txt',
    ).writeAsString('${lines.join('\n')}\n');
  } catch (_) {
    // 诊断写入失败绝不能影响正常流程
  }
}

/// 解析数据目录。
///
/// 直接用 `path_provider` 返回的**应用专属目录**，不再追加品牌子目录：
/// 该目录本身已经按应用隔离，再拼一层只会让路径更深且与平台习惯不符。
///
/// 实测结果（Windows）：
///
/// ```text
/// %APPDATA%\app.nestednote\nested\nested.db
/// ```
///
/// 其中 `nested` 段来自 Windows 可执行文件名，`app.nestednote` 来自包标识。
/// 各平台差异由 `path_provider` 负责，业务代码不需要关心。
Future<String> resolveDataDir() async {
  final base = await getApplicationSupportDirectory();
  return base.path;
}
