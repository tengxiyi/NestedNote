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
    this.deletedAtMs,
    this.notebookId,
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

  /// 删除时间（UTC 毫秒）；未删除时为 `null`。
  ///
  /// 回收站的排序与保留期倒计时都基于它，**不能用 `updatedAtMs` 代替**：
  /// 一篇三天前写、今天删的笔记，`updatedAtMs` 是三天前——
  /// 拿它算倒计时会给出一个与被删时间无关的**错数字**。
  /// （这正是加入这个字段之前的真实缺陷。）
  final int? deletedAtMs;

  /// 所属笔记本；`null` 表示未分类。
  ///
  /// 界面用它做一件事：在**非最底层**目录点"新建笔记"时，内核会把笔记
  /// 下潜到最底层的子目录，左栏选中项要**跟到实际落地的那个目录**去。
  /// 否则用户点了"在这里新建"，新笔记出现在别处而界面毫无提示。
  final String? notebookId;

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
      deletedAtMs: source.deletedAtMs?.toInt(),
      notebookId: source.notebookId,
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
  /// ## 默认 `true`：点父级目录能看到它下面的所有笔记
  ///
  /// 这个默认值**来回改过两次**，两次都有明确理由，记在这里免得再翻烧饼。
  ///
  /// **最初**是 `true`，理由："否则每建一层子笔记本，父级看上去就变空了。"
  ///
  /// **中间改成 `false`**，因为当时出现了"父级徽标 5、点进去只有 1"的矛盾。
  /// 但那时的真因不是聚合本身，而是**笔记可以挂在中间层**——
  /// 分类节点里躺着笔记，于是"父级有几篇"永远说不清。
  ///
  /// **现在恢复 `true`**，同时内核加了"新建笔记自动下潜到最底层子目录"
  /// （`NestedCore::resolve_note_notebook`）。两者合起来才成立：
  ///
  /// - 笔记只住在最底层 → 不存在"某个中间层藏着笔记"的歧义；
  /// - 点父级看到整棵子树 → 与"父级徽标 = 子树合计"一致；
  /// - 点叶目录看到的既是它自己、也是它的子树（叶子没有后代）。
  ///
  /// 于是不变量是：**徽标 = 点进这个目录能看到的行数**，
  /// 对每一层都成立，不需要用户理解"直属/合计"的区别。
  ///
  /// ## 历史数据里的例外
  ///
  /// 内核只对**新建**做下潜，已挂在中间层的笔记不搬（铁律 T1：
  /// 用户没要求搬家，擅自动他的数据更糟）。因此过渡期里，
  /// 中间层目录的徽标会大于"它自己那几篇"——这是正确的，
  /// 因为点进去确实能看到那么多。
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
/// 或 `flutter_riverpod` 导出），因此写不出这个类型名。用类型推断即可。
///
/// ## 界面应当 watch [noteListMergedProvider] 而不是它
///
/// 这个 provider 只负责"查一次库"。保存正文后列表里那一行的标题与时间会变，
/// 但**不能**为此重查整张列表——那会让中栏闪一下、滚动位置跳动。
/// 变化的行由 [noteListMergedProvider] 叠加，见那里的说明。
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

/// 刚被保存过的笔记（id → 最新摘要）。
///
/// ## 为什么需要这层"覆盖"
///
/// 保存正文后，列表里那一行的**标题与时间**会变，界面必须知道。
/// 但若为此 `invalidate` 整个列表：
///
/// - 列表整张重查、重建 → 中栏闪一下；
/// - 滚动位置可能跳。
///
/// 用户的原话是"保存笔记时应当是无感的，没有刷新的过程"。
/// 根因不是"保存慢"，而是**界面每次保存都把整张列表丢掉重来**。
///
/// 因此把"刚变过的几篇"单独存一层，由 [noteListMergedProvider] 合并到
/// 查询结果之上：列表不重查、不重排，只有那一行的内容被替换。
///
/// 这个做法比把列表改成 family-notifier 更简单，也不需要触碰
/// Riverpod 的 family-notifier API（本项目已多次踩到 Riverpod 3 的导出面问题）。
final recentlySavedNotesProvider =
    NotifierProvider<RecentlySavedNotes, Map<String, NoteItem>>(
      RecentlySavedNotes.new,
    );

/// "刚保存过的笔记"的持有者。
class RecentlySavedNotes extends Notifier<Map<String, NoteItem>> {
  @override
  Map<String, NoteItem> build() => const <String, NoteItem>{};

  /// 记下某篇笔记的最新摘要。
  void remember(NoteItem item) {
    state = <String, NoteItem>{...state, item.id: item};
  }

  /// 丢弃一条记录（例如该笔记被删了）。
  void forget(String id) {
    if (!state.containsKey(id)) {
      return;
    }
    state = <String, NoteItem>{...state}..remove(id);
  }

  /// 清空全部记录。
  ///
  /// 列表整体重查前调用：重查本身会拿到最新数据，留着旧覆盖层反而可能
  /// 与刚查到的结果冲突（例如那一篇其实已被删除或移走）。
  void forgetAll() {
    if (state.isEmpty) {
      return;
    }
    state = const <String, NoteItem>{};
  }
}

/// 笔记列表的**最终视图**：查询结果 + 刚保存过的覆盖。
///
/// 界面 watch 这个，而不是 [noteListProvider]。
///
/// ## 保留上一次的数据
///
/// 返回 `AsyncValue`，但底层 `FutureProvider` 在重查期间会保留旧值，
/// 因此界面不会"先闪成空再出现内容"——只要界面不把 `isLoading`
/// 当作"没有数据"（见 `NoteListPane` 的处理）。
final noteListMergedProvider =
    Provider.family<AsyncValue<List<NoteItem>>, NoteListQuery>((
      Ref ref,
      NoteListQuery query,
    ) {
      final AsyncValue<List<NoteItem>> source = ref.watch(
        noteListProvider(query),
      );
      final Map<String, NoteItem> overlay = ref.watch(
        recentlySavedNotesProvider,
      );
      final List<NoteItem>? items = source.value;
      if (items == null || overlay.isEmpty) {
        return source;
      }
      // 只替换**已存在**的行：覆盖层不该让不该出现的笔记冒出来
      // （例如它属于别的笔记本，或已进回收站）。
      bool changed = false;
      final List<NoteItem> merged = <NoteItem>[];
      for (final NoteItem item in items) {
        final NoteItem? fresh = overlay[item.id];
        if (fresh != null && fresh != item) {
          merged.add(fresh);
          changed = true;
        } else {
          merged.add(item);
        }
      }
      return changed ? AsyncData<List<NoteItem>>(merged) : source;
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

/// 一篇笔记的标题与正文（**一次读回**）。
///
/// ## 为什么单独有一个 provider
///
/// 编辑器要同时显示标题与正文。若分成两次读（`noteTextProvider` +
/// 从列表里找标题），会出现两种不一致：
///
/// - 两次读之间对方（或另一台设备）改了东西 → 标题是新的、正文是旧的；
/// - 列表缓存里的标题可能还没刷新 → 标题显示成旧的。
///
/// 一次 FFI 调用取回两样，界面拿到的就是**同一时刻**的快照。
final noteSnapshotProvider = FutureProvider.family<NoteSnapshot, String>((
  Ref ref,
  String id,
) async {
  final result = await rust.notesRead(id: id);
  return _unwrap(result, (rust.NotePayload payload) {
    return NoteSnapshot(
      title: payload.note?.title ?? '',
      text: payload.text ?? '',
    );
  });
});

/// 一篇笔记的标题与正文。
class NoteSnapshot {
  /// 构造。
  const NoteSnapshot({required this.title, required this.text});

  /// 标题。
  final String title;

  /// 正文（纯文本，块已展平）。
  final String text;
}

/// 新建笔记的结果。
///
/// 带上 [notebookId] 而不是只给笔记 id：内核可能把笔记下潜到别的目录
/// （见 [NoteActions.create]），调用方需要知道**实际落点**。
class CreatedNote {
  /// 构造。
  const CreatedNote({required this.id, required this.notebookId});

  /// 笔记标识。
  final String id;

  /// **实际生效**的所属笔记本；`null` 表示未分类。
  final String? notebookId;
}

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

  /// 创建空笔记，返回**实际落地**的位置。
  ///
  /// ## `notebookId` 只是"用户点在哪"，不一定是笔记最终在哪
  ///
  /// 内核的规则是"笔记只住在最底层目录"（`resolve_note_notebook`）：
  /// 用户在**非最底层**目录点新建时，笔记会被自动归到该层
  /// **排序第 1 的最底层子目录**。
  ///
  /// 因此返回 [CreatedNote]，让调用方拿到**实际生效的** `notebookId`
  /// 并据此把左栏选中项跟过去。否则用户点了"在这里新建"，
  /// 新笔记出现在别处，而界面毫无提示——那比"没反应"更让人困惑。
  ///
  /// 第一版只返回 `String`（笔记 id），调用方无从知道落点，
  /// 于是它在父目录新建后仍选中父目录，看到的是整棵子树——
  /// 新笔记混在中间，用户以为"没成功"。
  Future<CreatedNote> create({
    String title = '无标题笔记',
    String? notebookId,
  }) async {
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
    return CreatedNote(id: item.id, notebookId: item.notebookId);
  }

  /// 保存正文。
  ///
  /// ## 两条必须同时成立的行为
  ///
  /// **1. 正文缓存要失效。** 这是本项目一个**真实的数据丢失缺陷**的根因：
  /// 编辑器的 `_load()` 从 `noteTextProvider` 取正文，而保存后若只失效
  /// 列表与计数、不失效正文缓存，那么：
  ///
  /// - 用户输入 → 自动保存写库成功；
  /// - 切到另一篇笔记，再切回来；
  /// - `_load()` 从**缓存**读到保存前的旧文本，把用户刚写的内容覆盖掉。
  ///
  /// 症状正是"输入文字后切出去再切回来，笔记里是空的"——
  /// 数据其实已经落盘（Rust 侧实测可读回），是**界面用旧缓存把它盖住了**。
  ///
  /// **2. 列表要就地更新，不能整体重查。** 每次自动保存都重查整张列表
  /// 会让中栏闪一下、滚动位置跳动。用户的原话是"保存应当是无感的"。
  /// 改正文不会改变列表的组成与顺序，因此只需替换那一行
  /// （见 [NoteListNotifier.patchNote]）。
  ///
  /// 只有"组成或顺序会变"的操作才走 [_reloadLists]。
  Future<void> save(
    String id, {
    required String title,
    required String text,
  }) async {
    final result = await rust.notesSave(
      id: id,
      title: title,
      text: text,
      atMs: _nowMs(),
    );
    final NoteItem? updated = _unwrap(result, (rust.NotePayload payload) {
      return payload.note == null ? null : NoteItem.fromRust(payload.note!);
    });
    // 正文缓存必须失效，否则切回这篇笔记会看到旧内容
    _ref.invalidate(noteTextProvider(id));
    _ref.invalidate(noteSnapshotProvider(id));
    if (updated == null) {
      // 内核没回摘要（理论上不会），退回整体重查以保证界面正确
      _reloadLists();
      return;
    }
    // **不重查列表**，只把这一篇的最新摘要放进覆盖层。
    //
    // 这是"保存无感"的关键：列表不重查、不重排，因此中栏不闪、
    // 滚动位置不跳；而那一行的标题与时间仍然是最新的。
    //
    // 覆盖层是全局的（一个 Map），因此"全部笔记"与"当前笔记本"两个列表
    // 会自动都看到它，不需要逐个查询去通知。
    _ref.read(recentlySavedNotesProvider.notifier).remember(updated);
    // 计数与树上的"笔记数"确实变了，但失效它们不会重查整张列表。
    _ref.invalidate(noteCountProvider);
    _ref.invalidate(notebooksTreeProvider);
  }

  /// 复制一篇笔记，返回副本的标识。
  ///
  /// 正文与标签一并复制；附件只复制引用（内容寻址）；修订历史不复制。
  Future<String> duplicate(String id) async {
    final result = await rust.notesDuplicate(id: id, atMs: _nowMs());
    final NoteItem? item = _unwrap(
      result,
      (rust.NotePayload payload) =>
          payload.note == null ? null : NoteItem.fromRust(payload.note!),
    );
    if (item == null) {
      throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核未返回副本。');
    }
    _invalidateLists();
    return item.id;
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

  /// **彻底删除**一篇笔记（不可逆）。
  ///
  /// ## 为什么这个入口如此窄
  ///
  /// 全项目的实体硬删除只有两处：回收站到期自动清理，以及这里。
  /// 后者是**用户显式要求**的（在回收站里点"彻底删除"并二次确认），
  /// 界面上的调用点只有 [NoteListPane] 的回收站菜单一处。
  ///
  /// 刻意**不**提供"批量彻底删除"这类便利方法：
  /// 一次误操作销毁多条不可恢复的数据，代价远大于省下的点击。
  Future<void> purge(String id) async {
    final result = await rust.notesPurge(id: id);
    _unwrap(result, (rust.NotePayload _) => null);
    _invalidateLists();
  }

  /// 列表的**组成或顺序**可能变了 → 整体重查。
  ///
  /// 用在新建、删除、恢复、移动、复制这些场合。
  ///
  /// 与"就地替换"（见 [save]）的分工判据是：
  /// **这次变化会不会改变列表里有哪几行、或它们的先后**。
  /// 改正文不会（只是某一行的摘要变了）→ 就地替换，界面无感；
  /// 新建/删除会 → 必须重查。
  void _reloadLists() {
    // 重查前清掉覆盖层：重查本身已经会拿到最新数据，
    // 留着旧的覆盖反而可能与刚查到的结果冲突（例如那篇已被删除）。
    _ref.read(recentlySavedNotesProvider.notifier).forgetAll();
    // 按**值**失效：传一个新的等值对象即可命中同一个 provider
    // （NoteListQuery 实现了 == / hashCode，因此 new 一个也能匹配）。
    _ref.invalidate(noteListProvider);
    _ref.invalidate(noteCountProvider);
    _ref.invalidate(notebooksTreeProvider);
  }

  /// 兼容旧名（本次重构把 `_invalidateLists` 改名为语义更准的
  /// [`_reloadLists`]：它做的是"重查"，不是"失效一切"）。
  void _invalidateLists() => _reloadLists();
}

/// 写操作入口。
final Provider<NoteActions> noteActionsProvider = Provider<NoteActions>(
  NoteActions.new,
);

// ------------------------------------------------------------------ 当前笔记

/// 当前在右栏打开的笔记。
///
/// ## 为什么放进 provider 而不是留在 `NotesPage` 的 State 里
///
/// 菜单栏（「笔记」菜单）要能对"当前这篇"做复制、移动、标签、删除、
/// 查修订历史。若这个 id 留在 State 里，菜单就得持有一个 State 引用——
/// 那是把界面状态与"谁持有它"绑在一起，很快会变成互相引用。
///
/// 放进 provider 后，选笔记（列表点击）与用笔记（菜单动作）都只依赖它。
///
/// 存整个 [NoteItem] 而不是只存 id：菜单要根据标题显示
/// "删除「项目约定」"这类确认文案，只有 id 时还得再查一次；
/// 而且列表刷新后标题会变，这里存的对象也要跟着变（见 [refresh]）。
class OpenNote extends Notifier<NoteItem?> {
  @override
  NoteItem? build() => null;

  /// 打开某篇笔记。
  void open(NoteItem note) => state = note;

  /// 关闭（回到"未选择"状态）。
  void close() => state = null;

  /// 用最新的摘要刷新当前这篇（保存后标题可能变了）。
  ///
  /// **只在 id 相同时更新**：保存一篇笔记的过程中用户可能已经切走，
  /// 那时不该把当前打开的那一篇换掉——否则右栏会显示"另一篇的标题
  /// 配着这一篇的正文"。
  void refresh(NoteItem updated) {
    if (state?.id == updated.id) {
      state = updated;
    }
  }
}

/// 当前打开的笔记；`null` 表示没有打开任何笔记。
final openNoteProvider = NotifierProvider<OpenNote, NoteItem?>(OpenNote.new);

// ------------------------------------------------------------ 立即保存的通道

/// 「立即保存」的登记处。
///
/// ## 为什么需要一个回调登记处，而不是让菜单直接调 provider
///
/// "保存"不是内核动作，而是**编辑器当前的编辑状态**（标题 + 正文两个
/// 输入框的内容、是否正在保存、有没有未保存改动）。这些只有编辑器知道。
///
/// 菜单要触发它，只有两条路：
///
/// 1. 把编辑状态也搬进 provider —— 那等于把整个编辑器的内部状态公开，
///    任何地方都能改，很快会出现"谁把 _dirty 清了"这类难查的问题；
/// 2. **编辑器把「保存」这个方法登记出来**，菜单只负责调用。
///
/// 这里是第二条。登记是显式的、生命周期明确（编辑器 dispose 时注销），
/// 且菜单不需要知道编辑器内部长什么样。
///
/// `saveNow()` 返回 `false` 表示"当前没有编辑器，或没有可保存的内容"。
/// 菜单据此给不同的反馈，而不是假装成功。
class EditorSaveChannel extends Notifier<Future<void> Function()?> {
  @override
  Future<void> Function()? build() => null;

  /// 编辑器挂载时登记自己的保存方法。
  void register(Future<void> Function() save) => state = save;

  /// 编辑器卸载时注销。
  ///
  /// **必须传 `save` 做校验**：编辑器可能被快速替换（`ValueKey` 变化时
  /// 旧实例的 dispose 晚于新实例的 initState），无条件清空会把
  /// **新**编辑器的登记一起抹掉，表现为"菜单里的保存从此没反应"。
  void unregister(Future<void> Function() save) {
    if (state == save) {
      state = null;
    }
  }

  /// 触发一次保存。
  ///
  /// 返回 `false` 表示当前没有可保存的编辑器。
  Future<bool> saveNow() async {
    final Future<void> Function()? save = state;
    if (save == null) {
      return false;
    }
    await save();
    return true;
  }
}

/// 「立即保存」的登记处。
final editorSaveChannelProvider =
    NotifierProvider<EditorSaveChannel, Future<void> Function()?>(
      EditorSaveChannel.new,
    );

// ------------------------------------------------------------ 文本编辑通道

/// 编辑器暴露给菜单的**文本级**操作：套用块格式、读取当前正文。
///
/// ## 为什么是"改文本"而不是"改块"
///
/// 编辑器里用户看到的、光标所在的是**文本**。若菜单直接去改块模型，
/// 就必须自己回答一串问题：光标在哪个块里？选区跨了几个块？
/// 改完文本怎么回到界面？——而这些恰恰是 `TextEditingController`
/// 已经解决的事。
///
/// 因此格式菜单做的是**在选中行前面加/去标记**（`# `、`- [ ] `……），
/// 交给已有的保存路径把标记反解成块。这样：
///
/// - 所见即所得：用户立刻看到标记出现在文字里，可撤销（Ctrl+Z）；
/// - 不新开一条保存路径，也就不会出现"菜单改的格式没存上"；
/// - 与手工敲 `# ` 完全等价——**没有第二种语义**。
///
/// ## 为什么不用 provider 直接持有 controller
///
/// controller 是 `State` 的私有物，暴露出去会让别处能改它。
/// 这里只登记**一个方法**（套用格式），菜单拿不到 controller 本身。
class EditorTextChannel extends Notifier<Future<void> Function(String)?> {
  @override
  Future<void> Function(String)? build() => null;

  /// 编辑器挂载时登记"套用格式"的方法。
  void register(Future<void> Function(String) applyFormat) =>
      state = applyFormat;

  /// 编辑器卸载时注销（做同一性校验，理由见 `EditorSaveChannel`）。
  void unregister(Future<void> Function(String) applyFormat) {
    if (state == applyFormat) {
      state = null;
    }
  }

  /// 套用一种块格式。返回 `false` 表示当前没有编辑器。
  Future<bool> applyFormat(String marker) async {
    final Future<void> Function(String)? apply = state;
    if (apply == null) {
      return false;
    }
    await apply(marker);
    return true;
  }
}

/// 编辑器的文本级操作通道。
final editorTextChannelProvider =
    NotifierProvider<EditorTextChannel, Future<void> Function(String)?>(
      EditorTextChannel.new,
    );

// ------------------------------------------------------------ 编辑器重载通道

/// 「让编辑器重新读一遍当前笔记」的通道。
///
/// ## 为什么恢复修订后必须重载编辑器
///
/// 恢复改的是**内核里的文档**，而编辑器手里的还是旧内容。若不重载，
/// 编辑器的"已保存基准"仍是恢复前的文本——下一次自动保存会把
/// **旧内容再写回去**，恢复等于白做。这是数据安全，不是刷新偏好。
///
/// 与 [`EditorSaveChannel`] 同一个模式（登记/注销/同一性校验），
/// 因为要解决同一组生命周期问题：`initState` 不能改 provider、
/// `dispose` 不能用 `ref`、快速替换时旧实例的注销不能抹掉新实例
/// 的登记——这三个坑在 M1/M2 各踩过一次，见对应文档。
class EditorReloadChannel extends Notifier<Future<void> Function()?> {
  @override
  Future<void> Function()? build() => null;

  /// 编辑器挂载（下一帧）时登记自己的重载方法。
  void register(Future<void> Function() reload) => state = reload;

  /// 编辑器卸载时注销（同一性校验，理由见 `EditorSaveChannel`）。
  void unregister(Future<void> Function() reload) {
    if (state == reload) {
      state = null;
    }
  }

  /// 触发一次重载。返回 `false` 表示当前没有编辑器
  ///（例如"只看列表"模式下——此时没有东西需要刷新）。
  Future<bool> reloadNow() async {
    final Future<void> Function()? reload = state;
    if (reload == null) {
      return false;
    }
    await reload();
    return true;
  }
}

/// 编辑器重载通道。
final editorReloadChannelProvider =
    NotifierProvider<EditorReloadChannel, Future<void> Function()?>(
      EditorReloadChannel.new,
    );
