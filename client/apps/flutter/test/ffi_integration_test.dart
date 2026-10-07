// SPDX-License-Identifier: AGPL-3.0-or-later
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
import 'package:nested/src/rust/api/notes.dart';

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

  setUpAll(() async {
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

    // `RustLib.init()` 不允许重复调用（第二次抛 StateError），
    // 而同一个测试文件里的多个用例共享同一个进程 —— 因此在这里初始化一次。
    // 这也是生产代码用 ensureRustInitialized() 做幂等保护的同一条约束。
    await ensureRustInitialized();
  });

  test('Rust 内核能被加载，并在临时目录完成建库与自检', () async {
    final tempDir = Directory.systemTemp.createTempSync('nested-ffi-test-');
    addTearDown(() async {
      // 必须先关闭内核：它会持有 SQLite 连接与 WAL 文件，
      // 而 Windows 不允许删除仍被打开的文件（OS Error 32）。
      // 这不是测试的取巧——真实应用切换/迁移数据目录时也需要同样的顺序。
      await engineClose();
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

  test('笔记能在 Dart 侧完整走一遍增删改查（真实 FFI + SQLite）', () async {
    // 这条用例覆盖的是**跨语言边界**：Dart 调 Rust 写 SQLite 再读回来。
    // Rust 侧已有同逻辑的单元测试，但只有这条能证明
    // "生成的 Dart 绑定签名正确、PlatformInt64 转换正确、返回值结构正确"。
    final tempDir = Directory.systemTemp.createTempSync('nested-notes-test-');
    addTearDown(() async {
      await engineClose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final status = await startEngineInDirectory(tempDir.path);
    expect(status.ready, isTrue, reason: '引擎应就绪：${status.message}');

    final now = DateTime.now().millisecondsSinceEpoch;

    // 创建
    final created = await notesCreate(
      notebookId: null,
      title: '集成测试笔记',
      atMs: now,
    );
    expect(created.ok, isTrue, reason: '创建失败：${created.hint}');
    final note = created.value!.note!;
    expect(note.title, '集成测试笔记');
    expect(note.version.toInt(), 1);

    // 保存正文（两个段落）
    final saved = await notesSave(
      id: note.id,
      text: '第一段\n第二段',
      atMs: now + 1000,
    );
    expect(saved.ok, isTrue, reason: '保存失败：${saved.hint}');
    expect(saved.value!.note!.version.toInt(), 2, reason: '保存应递增修订号');

    // 读回：块已展平为按行分隔的纯文本
    final read = await notesRead(id: note.id);
    expect(read.ok, isTrue);
    expect(read.value!.text, '第一段\n第二段');

    // 出现在列表里
    final listed = await notesList(
      notebookId: null,
      includeDescendants: true,
      includeDeleted: false,
      limit: 0,
    );
    expect(listed.ok, isTrue);
    expect(
      listed.value!.notes.map((n) => n.id),
      contains(note.id),
      reason: '新建笔记应出现在列表中',
    );

    // 软删除后默认列表看不到，但 includeDeleted 仍能查到（铁律 T7）
    final deleted = await notesDelete(id: note.id, atMs: now + 2000);
    expect(deleted.ok, isTrue);

    final afterDelete = await notesList(
      notebookId: null,
      includeDescendants: true,
      includeDeleted: false,
      limit: 0,
    );
    expect(afterDelete.value!.notes.map((n) => n.id), isNot(contains(note.id)));

    final withDeleted = await notesList(
      notebookId: null,
      includeDescendants: true,
      includeDeleted: true,
      limit: 0,
    );
    expect(
      withDeleted.value!.notes.map((n) => n.id),
      contains(note.id),
      reason: '软删除的笔记必须仍可查询（不是物理删除）',
    );
  });

  test('无变更的保存不产生修订与同步操作（技术债 #11 的跨语言验证）', () async {
    // 这条语义是编辑器自动保存的前提：若"内容没变也产生一条修订"，
    // 自动保存就会把修订历史变成噪声，并让同步队列充满无意义操作。
    // Rust 侧已有单元测试；这里验证它在**真实 FFI + SQLite** 上同样成立。
    final tempDir = Directory.systemTemp.createTempSync('nested-save-test-');
    addTearDown(() async {
      await engineClose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    expect((await engineStart(dataDir: tempDir.path)).ready, isTrue);

    final now = DateTime.now().millisecondsSinceEpoch;
    final created = await notesCreate(
      notebookId: null,
      title: '保存语义',
      atMs: now,
    );
    final id = created.value!.note!.id;

    // 第一次保存：内容真的变了
    final first = await notesSave(id: id, text: '内容 A', atMs: now + 1000);
    expect(first.ok, isTrue);
    expect(first.value!.note!.version.toInt(), 2, reason: '有变更应递增版本');

    final afterFirst = await notesRevisionHistory(id: id, limit: 0);
    expect(afterFirst.length, 2, reason: '创建 + 一次保存 = 2 条修订');

    // 第二次保存：内容**完全相同**
    final second = await notesSave(id: id, text: '内容 A', atMs: now + 2000);
    expect(second.ok, isTrue);
    expect(second.value!.note!.version.toInt(), 2, reason: '内容未变时版本不得前进');

    final afterSecond = await notesRevisionHistory(id: id, limit: 0);
    expect(afterSecond.length, 2, reason: '内容未变时不得追加修订记录');

    // 第三次保存：内容又变了
    final third = await notesSave(id: id, text: '内容 B', atMs: now + 3000);
    expect(third.value!.note!.version.toInt(), 3);

    final afterThird = await notesRevisionHistory(id: id, limit: 0);
    expect(afterThird.length, 3);

    // 修订父链：v3 的父是 v2，v2 的父是 v1，v1 无父
    expect(afterThird[0].version.toInt(), 3);
    expect(afterThird[0].parentId, afterThird[1].id, reason: 'v3 的父应指向 v2');
    expect(afterThird[1].version.toInt(), 2);
    expect(afterThird[1].parentId, afterThird[2].id, reason: 'v2 的父应指向 v1');
    expect(afterThird[2].parentId, isNull, reason: '首条修订没有父');
  });
}
