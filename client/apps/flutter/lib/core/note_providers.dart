// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记数据层（Riverpod）——UI 与 Rust 内核之间的**唯一**通道。
//!
//! 《工程铁律》A2 / F1：UI 层不得直接接触存储与业务规则。
//! `lib/src/rust/**` 是 FRB 生成代码，除 `core/` 下的文件外任何地方都不得 import。
//!
//! 数据流：
//!
//! ```text
//! UI（notes_page / note_editor_page）
//!   → noteListProvider / noteActions（本文件）
//!     → lib/src/rust/api/notes.dart（FRB 生成绑定）
//!       → nested_app::api::notes（Rust 手写 API）
//!         → nested-core → nested-db → SQLite
//! ```
//!
//! ## 关于错误处理
//!
//! Rust 侧**不抛异常**，而是返回带 `code`/`hint` 的结构化结果（铁律 E1/E3）。
//! 因此这里把 `NoteResult` 翻译成 Dart 异常 `NoteFailure` 之前，先保留错误码——
//! 界面可以据此决定文案与是否可重试，而不是笼统地"出错了"。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/notes.dart' as rust;
import 'engine_providers.dart';
import 'notebook_providers.dart';

/// 一篇笔记在界面上的表示。
///
/// 刻意与生成类型解耦：生成类型的字段名会随 Rust 侧重构而变化，
/// 而界面只关心这几个值。
class NoteItem {
  /// 构造。
  const NoteItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.updatedAtMs,
    required this.version,
    required this.deleted,
  });

  /// 笔记标识。
  final String id;

  /// 标题。
  final String title;

  /// 摘要（列表第二行）。
  final String summary;

  /// 最后修改时间（UTC 毫秒）。
  final int updatedAtMs;

  /// 修订号。
  final int version;

  /// 是否在回收站。
  final bool deleted;

  /// 从生成类型转换。
  factory NoteItem.fromRust(rust.NoteSummary source) {
    return NoteItem(
      id: source.id,
      title: source.title,
      summary: source.summary,
      // FRB 把 i64 映射成 PlatformInt64，Windows 上是 int，其它平台可能是 BigInt，
      // 因此统一走 toInt() 而不是直接赋值。
      updatedAtMs: source.updatedAtMs.toInt(),
      version: source.version.toInt(),
      deleted: source.deleted,
    );
  }
}

/// 内核返回的业务失败。
///
/// 保留 `code` 是为了让界面能分支处理（铁律 E3：错误码可检索），
/// 例如 `NOT_FOUND` 可以提示"笔记已被删除"并刷新列表，
/// 而 `VALIDATION_ERROR` 应当让用户修改输入。
class NoteFailure implements Exception {
  /// 构造。
  const NoteFailure({required this.code, required this.hint});

  /// 稳定错误码（如 `NOT_FOUND`）。
  final String code;

  /// 面向用户的一句话提示。
  final String hint;

  @override
  String toString() => hint;
}

/// 当前毫秒时间戳（`at_ms` 由 Dart 提供，见 Rust 侧文档说明）。
int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// 把 Rust 的结构化结果转成"值或异常"。
T _unwrap<T>(
  rust.NoteResult result,
  T Function(rust.NotePayload payload) read,
) {
  if (!result.ok) {
    throw NoteFailure(
      code: result.code ?? 'UNKNOWN',
      // Rust 侧保证失败时一定有 hint；这里给个兜底以防契约被破坏
      hint: result.hint ?? '操作失败，请重试。',
    );
  }
  final payload = result.value;
  if (payload == null) {
    throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核返回了空结果。');
  }
  return read(payload);
}

/// 笔记列表的查询参数。
///
/// 用不可变值对象而不是多个 `family` 参数：Riverpod 的 family 参数需要
/// 可比较的相等性，值对象能自然支持 `==` / `hashCode`；
/// 且以后加过滤条件（标签、时间范围）时不必改所有调用点。
class NoteListQuery {
  /// 构造。
  const NoteListQuery({
    this.notebookId,
    this.includeDescendants = true,
    this.includeDeleted = false,
  });

  /// 限定笔记本；`null` 表示不限（"全部笔记"）。
  final String? notebookId;

  /// 是否包含子笔记本里的笔记。
  ///
  /// 默认为 `true`：用户点选一个父笔记本时，期望看到**它以及所有后代**的笔记，
  /// 否则每建一层子笔记本，父级看上去就变空了。
  final bool includeDescendants;

  /// 是否包含回收站里的笔记。
  final bool includeDeleted;

  @override
  bool operator ==(Object other) {
    return other is NoteListQuery &&
        other.notebookId == notebookId &&
        other.includeDescendants == includeDescendants &&
        other.includeDeleted == includeDeleted;
  }

  @override
  int get hashCode =>
      Object.hash(notebookId, includeDescendants, includeDeleted);

  @override
  String toString() =>
      'NoteListQuery(notebook: $notebookId, '
      'descendants: $includeDescendants, deleted: $includeDeleted)';
}

/// 笔记列表（按最近修改倒序）。
///
/// 过滤条件由 [NoteListQuery] 描述。
///
/// ## 为什么用 `final` 而不写显式类型
///
/// Riverpod 3 把 `FutureProviderFamily` 收窄为包内实现细节（未从 `riverpod`
/// 或 `flutter_riverpod` 导出），因此写不出这个类型名。用类型推断即可——
/// 调用侧 `ref.watch(noteListProvider(query))` 仍然是强类型的。
final noteListProvider = FutureProvider.family<List<NoteItem>, NoteListQuery>((
  Ref ref,
  NoteListQuery query,
) async {
  // 确保内核已经启动（首次进入时 engineProvider 会完成启动并在 FFI 侧
  // 把内核装进进程级单例，笔记操作依赖它）。
  await ref.watch(engineProvider.future);

  final result = await rust.notesList(
    notebookId: query.notebookId,
    includeDescendants: query.includeDescendants,
    includeDeleted: query.includeDeleted,
    limit: 0,
  );
  return _unwrap(result, (rust.NotePayload payload) {
    return payload.notes.map(NoteItem.fromRust).toList(growable: false);
  });
});

/// "全部笔记"的查询（不按笔记本过滤，不含回收站）。
const NoteListQuery kAllNotes = NoteListQuery();

/// 回收站查询（不限笔记本，含已删除）。
const NoteListQuery kDeletedNotes = NoteListQuery(includeDeleted: true);

/// 单篇笔记的正文（纯文本，块已展平）。
final noteTextProvider = FutureProvider.family<String, String>((
  Ref ref,
  String id,
) async {
  final result = await rust.notesRead(id: id);
  return _unwrap(result, (rust.NotePayload payload) => payload.text ?? '');
});

/// 笔记数量（不含回收站）。
final FutureProvider<int> noteCountProvider = FutureProvider<int>((
  Ref ref,
) async {
  await ref.watch(engineProvider.future);
  return (await rust.notesCount()).toInt();
});

/// 笔记写操作。
///
/// 所有写操作成功后都会 `invalidate` 列表与计数，从而让界面自动刷新——
/// 避免"保存了但列表没变"这类需要手动下拉才更新的体验问题。
class NoteActions {
  /// 构造。
  const NoteActions(this._ref);

  final Ref _ref;

  /// 创建空笔记，返回其标识。
  ///
  /// `notebookId` 给出时，笔记直接建在该笔记本下——这是"在某个笔记本里点新建"
  /// 的期望行为（否则新建的笔记会跑到"全部笔记"里，用户还得再手动移动一次）。
  Future<String> create({String title = '无标题笔记', String? notebookId}) async {
    final result = await rust.notesCreate(
      notebookId: notebookId,
      title: title,
      atMs: _nowMs(),
    );
    final NoteItem? item = _unwrap(
      result,
      (rust.NotePayload payload) =>
          payload.note == null ? null : NoteItem.fromRust(payload.note!),
    );
    if (item == null) {
      // Rust 侧契约要求创建成功必须返回笔记；缺失说明契约被破坏，
      // 此时报错比返回空 id 更容易定位。
      throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核未返回新建的笔记。');
    }
    _invalidateLists();
    return item.id;
  }

  /// 保存正文。
  Future<void> save(String id, String text) async {
    final result = await rust.notesSave(id: id, text: text, atMs: _nowMs());
    _unwrap(result, (rust.NotePayload payload) => payload.note);
    _invalidateLists();
  }

  /// 移入回收站（软删除，铁律 T7）。
  Future<void> delete(String id) async {
    final result = await rust.notesDelete(id: id, atMs: _nowMs());
    _unwrap(result, (rust.NotePayload _) => null);
    _invalidateLists();
  }

  /// 从回收站恢复。
  Future<void> restore(String id) async {
    final result = await rust.notesRestore(id: id, atMs: _nowMs());
    _unwrap(result, (rust.NotePayload _) => null);
    _invalidateLists();
  }

  void _invalidateLists() {
    // 按**值**失效：传一个新的等值对象即可命中同一个 provider
    // （NoteListQuery 实现了 == / hashCode，因此 new 一个也能匹配）。
    _ref.invalidate(noteListProvider);
    _ref.invalidate(noteCountProvider);
    _ref.invalidate(notebooksTreeProvider);
  }
}

/// 写操作入口。
final Provider<NoteActions> noteActionsProvider = Provider<NoteActions>(
  NoteActions.new,
);
