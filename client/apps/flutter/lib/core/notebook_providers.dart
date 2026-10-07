// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记本树的数据层（Riverpod）——UI 与 Rust 内核之间的唯一通道。
//!
//! 《工程铁律》A2 / F1：UI 层不得直接接触存储与业务规则。
//! `lib/src/rust/**` 是生成代码，除 `core/` 下的文件外任何地方都不得 import。
//!
//! ## 为什么树的组装放在 Rust 侧
//!
//! 界面的左栏是一棵可展开的笔记本树。若只从内核拿扁平列表，每个前端都要自己写
//! "按 parent_id 组装 + 深度优先排序 + 处理孤儿节点 + 统计子树笔记数"——
//! 这是典型的业务规则漏到 UI 层。
//!
//! 因此 [`notebooks_tree`] 已在 Rust 侧返回**按展开顺序排好的列表 + 深度**，
//! 界面只需要"顺序渲染 + 按深度缩进"。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/notes.dart' as rust;
import 'engine_providers.dart';
import 'note_providers.dart';

/// 一个笔记本节点。
class NotebookNode {
  /// 构造。
  const NotebookNode({
    required this.id,
    required this.name,
    required this.parentId,
    required this.depth,
    required this.noteCount,
  });

  /// 标识。
  final String id;

  /// 名称。
  final String name;

  /// 父笔记本标识（顶层为 null）。
  final String? parentId;

  /// 层级深度（顶层为 0），用于缩进。
  final int depth;

  /// 该笔记本**及其全部后代**中的笔记数量。
  final int noteCount;

  /// 从生成类型转换。
  factory NotebookNode.fromRust(rust.NotebookNode source) {
    return NotebookNode(
      id: source.id,
      name: source.name,
      parentId: source.parentId,
      depth: source.depth,
      noteCount: source.noteCount.toInt(),
    );
  }
}

/// 笔记本树（深度优先顺序）。
final FutureProvider<List<NotebookNode>> notebooksTreeProvider =
    FutureProvider<List<NotebookNode>>((Ref ref) async {
      // 确保内核已启动（首次进入时 engineProvider 会完成启动）
      await ref.watch(engineProvider.future);

      final rust.NoteResult result = await rust.notebooksTree();
      if (!result.ok) {
        // 失败必须**如实抛出**，不能退化成空列表：
        // 否则"查询失败"与"确实没有笔记本"在界面上长得一模一样，
        // 用户会以为数据丢了。这正是本 provider 第一版的错误做法
        // （当时 FFI 返回裸 Vec，失败被吞成空）。
        throw NoteFailure(
          code: result.code ?? 'UNKNOWN',
          hint: result.hint ?? '读取笔记本失败。',
        );
      }
      final List<rust.NotebookNode> nodes =
          result.value?.notebooks ?? const <rust.NotebookNode>[];
      return nodes.map(NotebookNode.fromRust).toList(growable: false);
    });

/// 当前选中的笔记本。
///
/// ## 为什么用 `NotifierProvider` 而不是 `StateProvider`
///
/// Riverpod 3 已把 `StateProvider` 从导出面移除（它鼓励"任意位置改状态"，
/// 难以追踪）。这里用一个显式的 [SelectedNotebook] 通知器：
/// 状态的**变更入口收敛成方法**（[SelectedNotebook.select] /
/// [SelectedNotebook.clear]），比到处写 `.state = x` 更容易审计。
///
/// `null` 表示"全部笔记"——这是一个明确的选项，而不是"尚未选择"。
class SelectedNotebook extends Notifier<String?> {
  @override
  String? build() => null;

  /// 选中某个笔记本。
  void select(String notebookId) => state = notebookId;

  /// 回到"全部笔记"。
  void clear() => state = null;
}

/// 当前选中的笔记本标识（`null` = 全部笔记）。
final NotifierProvider<SelectedNotebook, String?> selectedNotebookIdProvider =
    NotifierProvider<SelectedNotebook, String?>(SelectedNotebook.new);

/// 选中笔记本的名称（用于中栏标题）。选择"全部笔记"时为 `null`。
final Provider<String?> selectedNotebookNameProvider = Provider<String?>((
  Ref ref,
) {
  final String? id = ref.watch(selectedNotebookIdProvider);
  if (id == null) {
    return null;
  }
  final AsyncValue<List<NotebookNode>> tree = ref.watch(notebooksTreeProvider);
  return tree.value
      ?.where((NotebookNode node) => node.id == id)
      .map((NotebookNode node) => node.name)
      .firstOrNull;
});

/// 笔记本写操作。
class NotebookActions {
  /// 构造。
  const NotebookActions(this._ref);

  final Ref _ref;

  /// 创建笔记本；`parentId` 为 null 时创建顶层笔记本。
  Future<String> create({required String name, String? parentId}) async {
    final rust.NoteResult result = await rust.notebooksCreate(
      name: name,
      parentId: parentId,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '创建笔记本失败。',
      );
    }
    final String? id = result.value?.notebook?.id;
    if (id == null) {
      throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核未返回新建的笔记本。');
    }
    _invalidate();
    return id;
  }

  /// 移入回收站（软删除）。**不**级联删除其下笔记。
  ///
  /// 界面文案是「删除」，但语义是**移入回收站**——超过保留期才会被彻底删除。
  /// 文案与语义的这处差异是刻意的（用户要求与主流笔记应用一致），
  /// 因此删除后必须提示"在回收站中保留 N 天"，让不可逆的部分可预期。
  Future<void> delete(String id) async {
    final rust.NoteResult result = await rust.notebooksDelete(
      id: id,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '删除笔记本失败。',
      );
    }
    // 若删掉的正是当前选中的，回到"全部笔记"，避免中栏停在一个已消失的过滤条件上
    if (_ref.read(selectedNotebookIdProvider) == id) {
      _ref.read(selectedNotebookIdProvider.notifier).clear();
    }
    _invalidate();
  }

  /// 重命名笔记本。
  Future<void> rename(String id, String name) async {
    final rust.NoteResult result = await rust.notebooksRename(
      id: id,
      name: name,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '重命名失败。',
      );
    }
    _invalidate();
  }

  /// 把笔记本移动到另一个父节点下；`parentId` 为 null 表示移到顶层。
  ///
  /// 内核会拒绝成环的移动（`WOULD_CREATE_CYCLE`）。这里不预先过滤候选列表——
  /// 那需要在 UI 里重算一次子树关系，等于把内核已有的规则抄一遍（铁律 T4）。
  /// 直接让内核判断，把失败原因如实显示给用户。
  Future<void> move(String id, String? parentId) async {
    final rust.NoteResult result = await rust.notebooksMove(
      id: id,
      parentId: parentId,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '移动笔记本失败。',
      );
    }
    _invalidate();
  }

  /// 复制笔记本（含其下全部笔记与子笔记本，递归），返回新笔记本的标识。
  ///
  /// 附件的字节**不复制**——内容寻址让副本与原件指向同一份内容。
  /// 修订历史也不复制：副本从第 1 版重新开始。
  Future<String> duplicate(String id) async {
    final rust.NoteResult result = await rust.notebooksDuplicate(
      id: id,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '复制笔记本失败。',
      );
    }
    final String? newId = result.value?.notebook?.id;
    if (newId == null) {
      throw const NoteFailure(code: 'EMPTY_PAYLOAD', hint: '内核未返回副本。');
    }
    _invalidate();
    return newId;
  }

  /// 把笔记移到另一个笔记本。
  Future<void> moveNote(String noteId, String? notebookId) async {
    final rust.NoteResult result = await rust.notesMove(
      id: noteId,
      notebookId: notebookId,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!result.ok) {
      throw NoteFailure(
        code: result.code ?? 'UNKNOWN',
        hint: result.hint ?? '移动笔记失败。',
      );
    }
    _ref.invalidate(noteListProvider);
    _invalidate();
  }

  void _invalidate() {
    _ref.invalidate(notebooksTreeProvider);
    // 笔记列表带笔记本过滤，因此也要刷新
    _ref.invalidate(noteListProvider);
    _ref.invalidate(noteCountProvider);
  }
}

/// 笔记本写操作入口。
final Provider<NotebookActions> notebookActionsProvider =
    Provider<NotebookActions>(NotebookActions.new);

/// 树内过滤关键字（`null` 或空串表示不过滤）。
///
/// ## 为什么放在数据层而不是左栏的 State 里
///
/// 过滤结果要被"左栏渲染"与"属性/移动对话框的候选列表"共用。
/// 若它只存在于某个 widget 的 State 里，另一处就得自己再算一遍——
/// 两份实现迟早会出现"树里过滤了、移动对话框里没过滤"这类不一致。
///
/// 注意：这是**纯本地过滤**（在已加载的树上筛），不涉及全文搜索（FTS5）。
/// 笔记本数量通常在几十到几百，本地过滤足够快且无需索引。
class NotebookFilter extends Notifier<String> {
  @override
  String build() => '';

  /// 设置过滤词。
  void set(String value) => state = value;

  /// 清空过滤。
  void clear() => state = '';
}

/// 树内过滤关键字。
final NotifierProvider<NotebookFilter, String> notebookFilterProvider =
    NotifierProvider<NotebookFilter, String>(NotebookFilter.new);

/// 按关键字过滤后的笔记本树。
///
/// ## 过滤规则（刻意保持简单可预期）
///
/// - 大小写不敏感的子串匹配；
/// - **父节点命中时保留其整棵子树**——用户搜"工作"，期望看到"工作"下面
///   有什么，而不是只剩一个孤零零的父节点；
/// - **子节点命中时保留其所有祖先**——否则命中的节点会因为父节点被过滤掉
///   而在树里失去位置（深度信息就不成立了）。
///
/// 这两条合起来保证：过滤只做"隐藏"，绝不改变层级结构。
final Provider<List<NotebookNode>> filteredNotebookTreeProvider =
    Provider<List<NotebookNode>>((Ref ref) {
      final AsyncValue<List<NotebookNode>> tree = ref.watch(
        notebooksTreeProvider,
      );
      final String keyword = ref.watch(notebookFilterProvider).trim();
      final List<NotebookNode> all = tree.value ?? const <NotebookNode>[];
      if (keyword.isEmpty) {
        return all;
      }

      final String needle = keyword.toLowerCase();
      final Map<String, NotebookNode> byId = <String, NotebookNode>{
        for (final NotebookNode node in all) node.id: node,
      };

      // 先收集"直接命中"的节点，再向上补齐祖先、向下补齐子孙
      final Set<String> keep = <String>{};
      for (final NotebookNode node in all) {
        if (!node.name.toLowerCase().contains(needle)) {
          continue;
        }
        keep.add(node.id);
        // 向上：补祖先（父指针缺失时停止，避免坏数据造成死循环）
        String? cursor = node.parentId;
        while (cursor != null && keep.add(cursor)) {
          cursor = byId[cursor]?.parentId;
        }
      }
      // 向下：补子孙。按深度顺序扫一遍即可——深度升序保证了
      // "父节点先被判断"，因此一次遍历就能把整棵子树带上。
      for (final NotebookNode node in all) {
        if (node.parentId != null && keep.contains(node.parentId)) {
          keep.add(node.id);
        }
      }

      return <NotebookNode>[
        for (final NotebookNode node in all)
          if (keep.contains(node.id)) node,
      ];
    });
