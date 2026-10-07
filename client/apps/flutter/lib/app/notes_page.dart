// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记主界面 —— **三栏布局**。
//!
//! ```text
//! ┌────────────┬──────────────────┬────────────────────────────┐
//! │ 左栏        │ 中栏              │ 右栏                        │
//! │ 笔记本树     │ 笔记列表           │ 阅读 / 编辑区                │
//! │ 可多层级     │ 选中笔记本的笔记     │ 所选笔记的正文                │
//! └────────────┴──────────────────┴────────────────────────────┘
//! ```
//!
//! ## 为什么是三栏
//!
//! 这是笔记类应用被验证过的组织方式：**层级 → 集合 → 内容**。
//! 三者常驻同屏，用户不必来回切页面就能"在树里换笔记本、扫一眼列表、继续写"。
//!
//! ## 各栏的职责边界
//!
//! - **左栏**只负责选择笔记本。它不查笔记、不知道笔记内容。
//! - **中栏**只负责"当前笔记本下的笔记列表"。它不关心树的形状。
//! - **右栏**只负责展示与编辑**一篇**笔记。
//!
//! 这样切分的好处：任何一栏的数据变化都不会迫使另外两栏重算。
//! 例如保存一篇笔记只影响中栏的列表项与右栏自身，左栏完全不动。
//!
//! ## 分层（铁律 A2 / F1）
//!
//! 本文件不直接调用 FFI。所有数据来自 `core/` 下的 provider，
//! 写操作走 `NoteActions` / `NotebookActions`。
//! 这条约束由门禁 `A-LAYERING` 自动检查——本文件曾因为塞了一段诊断代码
//! 而违反它，后来把那部分整体移到了 `core/ui_diagnostics.dart`。
//!
//! ## 关于"界面看到了什么"的可观测性
//!
//! 界面状态由 `core/ui_diagnostics.dart` 在应用启动时订阅并落盘，
//! **不**由本文件负责。这样页面保持纯展示，诊断也能覆盖所有页面。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine.dart';
import '../core/engine_providers.dart';
import '../core/notebook_providers.dart';
import '../core/note_providers.dart';
import 'note_editor_page.dart';

/// 左栏宽度。
const double kSidebarWidth = 232;

/// 中栏宽度。
const double kNoteListWidth = 300;

/// 笔记主界面。
class NotesPage extends ConsumerStatefulWidget {
  /// 构造。
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  /// 是否显示回收站内容（影响中栏列表）。
  bool _showDeleted = false;

  /// 当前在右栏打开的笔记。
  String? _openNoteId;

  /// 左栏是否折叠（窄窗口时给内容让位）。
  bool _sidebarCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<EngineStatus> engine = ref.watch(engineProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(engine.value?.displayName ?? '拾光笔记'),
        titleSpacing: 4,
        leading: IconButton(
          tooltip: _sidebarCollapsed ? '展开笔记本栏' : '折叠笔记本栏',
          onPressed: () =>
              setState(() => _sidebarCollapsed = !_sidebarCollapsed),
          icon: Icon(_sidebarCollapsed ? Icons.menu : Icons.menu_open),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: _showDeleted ? '隐藏回收站' : '显示回收站',
            onPressed: () => setState(() => _showDeleted = !_showDeleted),
            icon: Icon(
              _showDeleted ? Icons.delete : Icons.delete_outlined,
              color: _showDeleted
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
          IconButton(
            tooltip: '引擎自检',
            onPressed: () => _showDiagnostics(context),
            icon: const Icon(Icons.monitor_heart_outlined),
          ),
        ],
      ),
      body: switch (engine) {
        AsyncError(:final Object error) => _FailureView(message: '$error'),
        AsyncData() => _ThreePane(
          showDeleted: _showDeleted,
          sidebarCollapsed: _sidebarCollapsed,
          openNoteId: _openNoteId,
          onOpenNote: (String? id) => setState(() => _openNoteId = id),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  void _showDiagnostics(BuildContext context) {
    final EngineStatus? status = ref.read(engineProvider).value;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('引擎自检'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final EngineCheck check in status?.checks ?? <EngineCheck>[])
                Row(
                  children: <Widget>[
                    Icon(
                      check.passed ? Icons.check_circle : Icons.error,
                      size: 18,
                      color: check.passed ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(check.name),
                  ],
                ),
              const SizedBox(height: 12),
              SelectableText(
                '数据库：${status?.databasePath ?? '（未知）'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 三栏容器。
class _ThreePane extends StatelessWidget {
  const _ThreePane({
    required this.showDeleted,
    required this.sidebarCollapsed,
    required this.openNoteId,
    required this.onOpenNote,
  });

  final bool showDeleted;
  final bool sidebarCollapsed;
  final String? openNoteId;
  final ValueChanged<String?> onOpenNote;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!sidebarCollapsed) ...<Widget>[
          const SizedBox(width: kSidebarWidth, child: NotebookSidebar()),
          const VerticalDivider(width: 1),
        ],
        SizedBox(
          width: kNoteListWidth,
          child: NoteListPane(
            showDeleted: showDeleted,
            openNoteId: openNoteId,
            onOpenNote: onOpenNote,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: openNoteId == null
              ? const _EmptyReadingPane()
              : NoteEditorPane(
                  // key 让"切换到另一篇笔记"时重建编辑状态，
                  // 否则会沿用上一篇的文本与"已保存"基准
                  key: ValueKey<String>(openNoteId!),
                  noteId: openNoteId!,
                ),
        ),
      ],
    );
  }
}

// ============================================================ 左栏：笔记本树

/// 左栏：笔记本树 + 快捷入口。
class NotebookSidebar extends ConsumerWidget {
  /// 构造。
  const NotebookSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<NotebookNode>> tree = ref.watch(
      notebooksTreeProvider,
    );
    final String? selected = ref.watch(selectedNotebookIdProvider);
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 2),
          child: Row(
            children: <Widget>[
              Text('笔记本', style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '新建顶层笔记本',
                visualDensity: VisualDensity.compact,
                onPressed: () => _createNotebook(context, ref, null),
                icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              ),
            ],
          ),
        ),
        // "全部笔记"是一个显式条目，而不是"未选择"的隐含状态——
        // 用户需要能明确地回到"看所有笔记"。
        _SidebarTile(
          icon: Icons.all_inbox_outlined,
          label: '全部笔记',
          selected: selected == null,
          depth: 0,
          onTap: () => ref.read(selectedNotebookIdProvider.notifier).clear(),
        ),
        const Divider(height: 10),
        Expanded(
          child: switch (tree) {
            AsyncLoading() => const Center(child: CircularProgressIndicator()),
            AsyncError(:final Object error) => Padding(
              padding: const EdgeInsets.all(12),
              child: Text('$error', style: theme.textTheme.bodySmall),
            ),
            AsyncData(:final List<NotebookNode> value) when value.isEmpty =>
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '还没有笔记本。\n用上方按钮新建一个。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            AsyncData(:final List<NotebookNode> value) => ListView.builder(
              itemCount: value.length,
              itemBuilder: (BuildContext context, int index) {
                final NotebookNode node = value[index];
                return _SidebarTile(
                  icon: node.depth == 0
                      ? Icons.folder_outlined
                      : Icons.subdirectory_arrow_right,
                  label: node.name,
                  trailingCount: node.noteCount,
                  selected: node.id == selected,
                  depth: node.depth,
                  onTap: () => ref
                      .read(selectedNotebookIdProvider.notifier)
                      .select(node.id),
                  onLongPress: () => _notebookMenu(context, ref, node),
                );
              },
            ),
          },
        ),
      ],
    );
  }

  /// 长按笔记本：新建子笔记本 / 删除。
  Future<void> _notebookMenu(
    BuildContext context,
    WidgetRef ref,
    NotebookNode node,
  ) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(node.name),
              subtitle: Text('共 ${node.noteCount} 篇笔记（含子笔记本）'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建子笔记本'),
              onTap: () => Navigator.of(sheetContext).pop('child'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('移入回收站'),
              subtitle: const Text('其中的笔记不会被删除'),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );

    if (!context.mounted) {
      return;
    }
    switch (action) {
      case 'child':
        await _createNotebook(context, ref, node.id);
      case 'delete':
        await _deleteNotebook(context, ref, node);
    }
  }

  Future<void> _createNotebook(
    BuildContext context,
    WidgetRef ref,
    String? parentId,
  ) async {
    final String? name = await promptText(
      context,
      title: parentId == null ? '新建笔记本' : '新建子笔记本',
      hint: '例如：工作 / 项目 A',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(notebookActionsProvider)
          .create(name: name.trim(), parentId: parentId);
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _deleteNotebook(
    BuildContext context,
    WidgetRef ref,
    NotebookNode node,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('删除笔记本「${node.name}」？'),
        content: Text(
          node.noteCount > 0
              // 明确告知"笔记不会被删"——这是用户最担心的事
              ? '该笔记本（含子笔记本）中有 ${node.noteCount} 篇笔记。\n\n'
                    '笔记不会被删除，只是不再出现在笔记本列表里。'
              : '该笔记本下没有笔记。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(notebookActionsProvider).delete(node.id);
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }
}

/// 每一层笔记本的缩进量（逻辑像素）。
const double kIndentPerLevel = 13;

/// 标签距离左边缘的基础内边距。
const double kIndentBase = 8;

/// 缩进总量上限。左栏宽 [kSidebarWidth]，留下名称的显示空间。
const double kIndentMax = 118;

/// 计算某个层级在左栏中的缩进量。
///
/// ## 为什么要"封顶"而不是"一直加"
///
/// 层级没有硬上限（数据层不限制深度），但左栏宽度固定。
/// 若无限累加，深层级的名称会被挤出可视区域。
///
/// ## 为什么封顶前必须保证"每层都不同"
///
/// 第一版写成了 `depth.clamp(0, 6) * 14`——**第 7 层开始缩进完全相同**，
/// 于是两个不同层级的兄弟节点看起来一样深，用户无法判断自己在哪一层。
/// 「封顶」应当封的是**总宽度**，而不是**层级的区分度**：
/// 在到达上限之前，每一层都必须给出不同的缩进。
///
/// 这样在第 1–9 层之间层级分明；再深则缩进不再增加（但用户仍可通过
/// 展开/折叠与名称判断），这是宽度受限下的合理取舍。
///
/// 提取成独立的纯函数是为了**可测试**：缩进是层级可视化的核心，
/// 而它在 widget 里很难断言。
double notebookIndent(int depth) {
  // 负深度不该出现，但真出现了也不能把内容推到屏幕外
  final int safeDepth = depth < 0 ? 0 : depth;
  final double wanted = kIndentBase + (safeDepth * kIndentPerLevel);
  return wanted > kIndentMax ? kIndentMax : wanted;
}

/// 左栏的一行。
class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.depth,
    required this.onTap,
    this.trailingCount,
    this.onLongPress,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final int depth;
  final VoidCallback onTap;
  final int? trailingCount;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double indent = notebookIndent(depth);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? theme.colorScheme.secondaryContainer : null,
        padding: EdgeInsets.fromLTRB(indent, 7, 8, 7),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 17,
              color: selected
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (trailingCount != null && trailingCount! > 0)
              Text(
                '${trailingCount!}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================ 中栏：笔记列表

/// 中栏：当前笔记本下的笔记列表。
class NoteListPane extends ConsumerWidget {
  /// 构造。
  const NoteListPane({
    required this.showDeleted,
    required this.openNoteId,
    required this.onOpenNote,
    super.key,
  });

  /// 是否显示回收站内容。
  final bool showDeleted;

  /// 当前打开的笔记（高亮）。
  final String? openNoteId;

  /// 打开某篇笔记（或关闭：传 null）。
  final ValueChanged<String?> onOpenNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? notebookId = ref.watch(selectedNotebookIdProvider);
    final String? notebookName = ref.watch(selectedNotebookNameProvider);
    final NoteListQuery query = NoteListQuery(
      // 回收站视图展示**全部**笔记本的已删除笔记，
      // 否则用户会以为"只删了当前笔记本里的"
      notebookId: showDeleted ? null : notebookId,
      includeDeleted: showDeleted,
    );
    final AsyncValue<List<NoteItem>> notes = ref.watch(noteListProvider(query));
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 标题栏：明确当前过滤范围
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      showDeleted ? '回收站' : (notebookName ?? '全部笔记'),
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${notes.value?.length ?? 0} 篇笔记',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: showDeleted ? '回收站中不能新建' : '在此新建笔记',
                visualDensity: VisualDensity.compact,
                onPressed: showDeleted
                    ? null
                    : () => _createNote(context, ref, notebookId),
                icon: const Icon(Icons.add, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (notes) {
            AsyncLoading() => const Center(child: CircularProgressIndicator()),
            AsyncError(:final Object error) => Padding(
              padding: const EdgeInsets.all(14),
              child: Text('$error', style: theme.textTheme.bodySmall),
            ),
            AsyncData(:final List<NoteItem> value) when value.isEmpty =>
              _EmptyNoteList(showDeleted: showDeleted),
            AsyncData(:final List<NoteItem> value) => ListView.builder(
              itemCount: value.length,
              itemBuilder: (BuildContext context, int index) {
                final NoteItem note = value[index];
                return _NoteRow(
                  note: note,
                  selected: note.id == openNoteId,
                  onTap: () => onOpenNote(note.id),
                  onLongPress: () => _noteMenu(context, ref, note, showDeleted),
                );
              },
            ),
          },
        ),
      ],
    );
  }

  Future<void> _createNote(
    BuildContext context,
    WidgetRef ref,
    String? notebookId,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final String id = await ref
          .read(noteActionsProvider)
          .create(notebookId: notebookId);
      onOpenNote(id);
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _noteMenu(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
    bool showDeleted,
  ) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(note.title),
              subtitle: Text('v${note.version}'),
            ),
            const Divider(height: 1),
            if (showDeleted)
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复'),
                onTap: () => Navigator.of(sheetContext).pop('restore'),
              )
            else ...<Widget>[
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('移动到笔记本…'),
                onTap: () => Navigator.of(sheetContext).pop('move'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('移入回收站'),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
            ],
          ],
        ),
      ),
    );
    if (!context.mounted) {
      return;
    }

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'restore':
          await ref.read(noteActionsProvider).restore(note.id);
        case 'delete':
          await ref.read(noteActionsProvider).delete(note.id);
          if (openNoteId == note.id) {
            onOpenNote(null);
          }
        case 'move':
          await _moveNote(context, ref, note);
      }
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _moveNote(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
  ) async {
    final List<NotebookNode> tree =
        ref.read(notebooksTreeProvider).value ?? const <NotebookNode>[];
    final String? target = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: const Text('移动到笔记本'),
        children: <Widget>[
          SimpleDialogOption(
            // 用空串表示"移出笔记本"；null 表示"用户取消"——
            // 两者必须区分，否则无法表达"移出"这个合法操作
            onPressed: () => Navigator.of(dialogContext).pop(''),
            child: const Text('（移出笔记本）'),
          ),
          for (final NotebookNode node in tree)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(node.id),
              child: Padding(
                // 与左栏用同一套缩进规则，避免两处的层级观感不一致
                padding: EdgeInsets.only(left: notebookIndent(node.depth)),
                child: Text(node.name, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
    if (target == null || !context.mounted) {
      return;
    }
    await ref
        .read(notebookActionsProvider)
        .moveNote(note.id, target.isEmpty ? null : target);
  }
}

/// 中栏的一行笔记。
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final NoteItem note;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (note.deleted)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.delete_outline,
                      size: 14,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              note.summary.isEmpty ? '（空）' : note.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              formatListTime(note.updatedAtMs),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把 UTC 毫秒格式化成列表里显示的时间。
///
/// 规则（与常见笔记应用一致）：
/// - 今天 → 只显示时间
/// - 今年 → 月-日
/// - 更早 → 年-月-日
///
/// 公开（非下划线开头）是为了能在 widget 测试里直接断言格式，
/// 不必去解析渲染后的文本。
String formatListTime(int utcMs, {DateTime? now}) {
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(utcMs);
  final DateTime reference = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');

  final bool sameDay =
      time.year == reference.year &&
      time.month == reference.month &&
      time.day == reference.day;
  if (sameDay) {
    return '${two(time.hour)}:${two(time.minute)}';
  }
  if (time.year == reference.year) {
    return '${two(time.month)}-${two(time.day)}';
  }
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// 中栏空列表提示。
class _EmptyNoteList extends StatelessWidget {
  const _EmptyNoteList({required this.showDeleted});

  final bool showDeleted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              showDeleted ? Icons.delete_outline : Icons.note_add_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              showDeleted ? '回收站是空的' : '这里还没有笔记',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (!showDeleted) ...<Widget>[
              const SizedBox(height: 6),
              Text('点右上方 + 新建一篇', style: theme.textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// 右栏未选择笔记时的提示。
class _EmptyReadingPane extends StatelessWidget {
  const _EmptyReadingPane();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.article_outlined,
            size: 52,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 14),
          Text('从左侧选择一篇笔记', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('或在中栏点 + 新建', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 让用户输入一段文本（新建笔记本用）。
///
/// 公开（非下划线开头）以便被测试直接复用。
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String? initial,
}) async {
  final TextEditingController controller = TextEditingController(
    text: initial ?? '',
  );
  try {
    return await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

/// 失败视图（**不**显示堆栈，铁律 E2）。
class _FailureView extends StatelessWidget {
  const _FailureView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text('无法读取笔记', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
