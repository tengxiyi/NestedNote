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
