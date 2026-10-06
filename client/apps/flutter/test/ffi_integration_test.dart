// Flutter ↔ Rust 集成冒烟测试（P0-5 的验收）。
//
// 与 test/widget_test.dart 的区别：Widget 测试用假数据验证 UI 装配，
// 本测试**真实调用 Rust 内核**：加载动态库 → 建库 → 执行迁移 → 完整性校验。
//
// ## 运行前提：先构建 Rust 动态库
//
// ```powershell
// cd client
// cargo build -p nested_app --release
// ```
//
// ## 为什么要设 FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR
//
// `flutter_rust_bridge` 的默认加载器按**相对路径** `../rust/target/release/`
// 查找动态库（相对运行时的当前目录）。在 `flutter test` 下这个相对路径不可靠，
// 因此这里显式给出绝对路径。
//
// 这不影响真实应用：应用由 Cargokit（rust_builder 插件）在构建时把 Rust 编译好
// 并打进应用目录，运行期靠 Windows 的 DLL 搜索顺序从 exe 同目录加载，
// 根本不走 `ioDirectory` 这条分支。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nested/core/engine_providers.dart';
import 'package:nested/src/rust/frb_generated.dart';

/// 定位 Rust 动态库目录：`client/target/release`。
///
/// `flutter test` 的工作目录是应用目录（`client/apps/flutter`），
/// 因此往上两级就是 `client`。
Directory rustLibraryDirectory() {
  final appDir = Directory.current;
  final clientDir = Directory('${appDir.path}/../..');
  return Directory('${clientDir.path}/target/release');
}

void main() {
  // 平台通道与 binding 在测试环境不可用，本测试刻意绕开它们
  // （通过 startEngineInDirectory 直接指定数据目录）。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final libDir = rustLibraryDirectory();
    final dll = File('${libDir.path}/nested_app.dll');
    expect(
      dll.existsSync(),
      isTrue,
      reason: '未找到 ${dll.path}；请先执行 `cargo build -p nested_app --release`',
    );

    if (Platform
            .environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR']
            ?.isEmpty ??
        true) {
      stdout.writeln(
        '[ffi] 提示：建议设置环境变量 '
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=${libDir.path} '
        '以获得确定的库路径（FRB 默认按相对路径查找）。',
      );
    }
  });

  test('Rust 内核能被加载，并在临时目录完成建库与自检', () async {
    await RustLib.init();

    final tempDir = Directory.systemTemp.createTempSync('nested-ffi-test-');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final status = await startEngineInDirectory(tempDir.path);

    // 打印到 stdout，失败时可直接看到原因（不必依赖 UI 或调试器）
    stdout.writeln('[ffi] ready=${status.ready}');
    stdout.writeln('[ffi] displayName=${status.displayName}');
    stdout.writeln('[ffi] version=${status.version}');
    stdout.writeln('[ffi] protocolVersion=${status.protocolVersion}');
    stdout.writeln('[ffi] databasePath=${status.databasePath}');
    stdout.writeln('[ffi] message=${status.message}');
    for (final check in status.checks) {
      stdout.writeln('[ffi] check ${check.name}=${check.passed}');
    }

    expect(status.ready, isTrue, reason: '引擎应就绪，实际信息：${status.message}');
    expect(status.displayName, '拾光笔记', reason: '显示名应来自 Rust branding 模块');
    expect(status.checks, isNotEmpty);
    expect(status.checks.every((c) => c.passed), isTrue);
    expect(status.databasePath, isNotNull);

    final database = File(status.databasePath!);
    expect(database.existsSync(), isTrue, reason: '数据库文件应真实存在');
    expect(database.lengthSync(), greaterThan(0), reason: '数据库不应是空文件');
    expect(database.path, contains(tempDir.path), reason: '数据库应建在传入的目录里');
  });
}
