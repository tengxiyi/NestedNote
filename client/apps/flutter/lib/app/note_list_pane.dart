// SPDX-License-Identifier: AGPL-3.0-or-later
//! 中栏：当前笔记本下的笔记列表。
//!
//! ## 职责边界
//!
//! 中栏**只**负责"当前过滤条件下的笔记列表"。它不关心树的形状，
//! 也不渲染笔记内容。因此切换笔记本时只有这里与右栏需要重建。
//!
//! ## 回收站视图的两处特殊处理
//!
//! 1. 展示**全部**笔记本的已删除笔记，而不是"当前笔记本里的已删除笔记"——
//!    否则用户会以为"只删了当前笔记本里的"，找不到别处删的东西。
//! 2. 每行显示**剩余保留天数**。删除是不可逆流程的起点，
//!    用户必须能看见倒计时（见 `core/trash_providers.dart`）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notebook_providers.dart';
import '../core/note_providers.dart';
import '../core/trash_providers.dart';
import 'dialogs.dart';
import 'notebook_sidebar.dart';
import 'tag_editor.dart';
import 'icons.dart';

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
    final int retention = ref.watch(trashRetentionDaysProvider).value ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(context, ref, notes, notebookName, notebookId, theme),
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
                  retentionDays: showDeleted ? retention : null,
                  onTap: () => onOpenNote(note.id),
                  onLongPress: () => _noteMenu(context, ref, note, retention),
                );
              },
            ),
          },
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<NoteItem>> notes,
    String? notebookName,
    String? notebookId,
    ThemeData theme,
  ) {
    return Padding(
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
            icon: const Icon(kNewNoteIcon, size: 20),
          ),
        ],
      ),
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

  /// 笔记的上下文菜单。
  ///
  /// 回收站中与正常列表里的菜单**刻意不同**：
  /// - 正常列表：打开 / 移动 / 删除 / 属性
  /// - 回收站：恢复 / **彻底删除**（不可逆，需二次确认）
  ///
  /// 把"彻底删除"只放在回收站里，是为了把不可逆操作从日常路径上挪开——
  /// 用户在正常列表里删东西时期望的是"先放起来"，不是"立刻销毁"。
  Future<void> _noteMenu(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
    int retention,
  ) async {
    final List<ContextMenuItem<String>> items = showDeleted
        ? const <ContextMenuItem<String>>[
            ContextMenuItem<String>(
              value: 'open',
              label: '打开',
              icon: Icons.open_in_new,
            ),
            ContextMenuItem<String>.divider(),
            ContextMenuItem<String>(
              value: 'restore',
              label: '恢复',
              icon: kRestoreIcon,
            ),
            ContextMenuItem<String>(
              value: 'purge',
              label: '彻底删除',
              icon: Icons.delete_forever_outlined,
              destructive: true,
            ),
            ContextMenuItem<String>.divider(),
            ContextMenuItem<String>(
              value: 'properties',
              label: '属性',
              icon: Icons.info_outline,
            ),
          ]
        : const <ContextMenuItem<String>>[
            ContextMenuItem<String>(
              value: 'open',
              label: '打开',
              icon: Icons.open_in_new,
            ),
            ContextMenuItem<String>.divider(),
            ContextMenuItem<String>(
              value: 'move',
              label: '移动到…',
              icon: kMoveIcon,
              shortcut: 'Alt+Shift+M',
            ),
            ContextMenuItem<String>(
              value: 'tags',
              label: '标签…',
              icon: kEditTagsIcon,
            ),
            ContextMenuItem<String>(
              value: 'duplicate',
              label: '复制一份',
              icon: kDuplicateIcon,
            ),
            ContextMenuItem<String>.divider(),
            ContextMenuItem<String>(
              value: 'delete',
              label: '删除',
              icon: kRecycleBinIcon,
              destructive: true,
            ),
            ContextMenuItem<String>.divider(),
            ContextMenuItem<String>(
              value: 'properties',
              label: '属性',
              icon: Icons.info_outline,
            ),
          ];

    final String? action = await showContextMenu<String>(
      context,
      title: note.title,
      items: items,
    );
    if (action == null || !context.mounted) {
      return;
    }

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'open':
          onOpenNote(note.id);
        case 'restore':
          await ref.read(noteActionsProvider).restore(note.id);
        case 'purge':
          await _purgeNote(context, ref, note);
        case 'delete':
          await ref.read(noteActionsProvider).delete(note.id);
          if (openNoteId == note.id) {
            onOpenNote(null);
          }
          _notifyMovedToTrash(messenger, retention);
        case 'move':
          await _moveNote(context, ref, note);
        case 'tags':
          await _editTags(context, ref, note);
        case 'duplicate':
          await _duplicateNote(context, ref, note);
        case 'properties':
          await _showProperties(context, note);
      }
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  /// 编辑标签。
  ///
  /// 保存后把笔记**重新打开一次**：右栏的编辑器是按 noteId 取正文的，
  /// 标签变化不影响它；但中栏的行如果有标签展示，需要它重绘。
  /// 刷新由 `TagActions` 的 `invalidate` 负责，这里不必额外做什么。
  Future<void> _editTags(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
  ) async {
    await showTagEditor(context, noteId: note.id, noteTitle: note.title);
  }

  /// 复制一份。
  ///
  /// 复制完**不自动打开**副本：用户点"复制一份"通常是为了做点别的，
  /// 立刻把右栏切走会打断他手上的事。改为提示一句"已复制"，
  /// 副本就出现在列表里（标题带「（副本）」），需要时再点。
  Future<void> _duplicateNote(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String newId = await ref.read(noteActionsProvider).duplicate(note.id);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已复制一份（标题带「（副本）」）。'),
        action: SnackBarAction(
          label: '打开副本',
          // 用返回值里的 id，而不是自己拼——与标签复活同理，
          // 调用方不该假设自己知道新实体的 id
          onPressed: () => onOpenNote(newId),
        ),
      ),
    );
  }

  /// 彻底删除（不可逆）。**必须二次确认**，且确认按钮写明后果。
  Future<void> _purgeNote(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
  ) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: '彻底删除「${note.title}」？',
      message:
          '此操作**不可撤销**：内容会从数据库中永久移除，无法再恢复。\n\n'
          '如果只是想让它消失，用「删除」放进回收站即可。',
      confirmLabel: '永久删除',
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(noteActionsProvider).purge(note.id);
      if (openNoteId == note.id) {
        onOpenNote(null);
      }
      messenger.showSnackBar(const SnackBar(content: Text('已彻底删除。')));
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

  Future<void> _showProperties(BuildContext context, NoteItem note) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(note.title),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _propertyRow('修订', '第 ${note.version} 版'),
            _propertyRow('修改时间', formatListTime(note.updatedAtMs)),
            _propertyRow('状态', note.deleted ? '在回收站中' : '正常'),
            _propertyRow('标识', note.id),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 属性对话框里的一行。
Widget _propertyRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(
        width: 72,
        child: Text(label, style: const TextStyle(color: Colors.grey)),
      ),
      Expanded(child: SelectableText(value)),
    ],
  ),
);

/// 中栏的一行笔记。
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.retentionDays,
  });

  final NoteItem note;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 非 null 时显示"还剩 N 天"（回收站视图用）。
  final int? retentionDays;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 回收站里显示倒计时。这是"不可逆操作可预期"的落点：
    // 用户必须能看见内容还有多久会被自动清理。
    final String? countdown = retentionDays == null
        ? null
        : () {
            final TrashAge age = trashAgeOf(
              deletedAtMs: note.updatedAtMs,
              retentionDays: retentionDays!,
              nowMs: DateTime.now().millisecondsSinceEpoch,
            );
            if (age.expired) {
              return '已过期，下次启动将清理';
            }
            if (age.remainingDays <= 0) {
              return '今天到期';
            }
            return '还剩 ${age.remainingDays} 天';
          }();

    // 已过期的条目用警示色：它下次启动就会消失
    final bool expiring =
        retentionDays != null &&
        trashAgeOf(
          deletedAtMs: note.updatedAtMs,
          retentionDays: retentionDays!,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        ).expired;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Container(
        color: selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                // 笔记图标：**任何位置都用 kNoteIcon**（规则 1）。
                // 回收站里的笔记形状不变，只改颜色（规则 3）——
                // 若改成垃圾桶图标，用户会以为"这是一条删除操作"而不是"一篇被删的笔记"。
                Icon(
                  kNoteIcon,
                  size: 15,
                  color: note.deleted
                      ? theme.colorScheme.outline
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: note.deleted
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
                if (note.deleted)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Tooltip(
                      message: '在回收站中',
                      child: Icon(
                        kInRecycleBinBadgeIcon,
                        size: 14,
                        color: theme.colorScheme.outline,
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
            Row(
              children: <Widget>[
                Text(
                  formatListTime(note.updatedAtMs),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                if (countdown != null) ...<Widget>[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      countdown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: expiring
                            ? theme.colorScheme.error
                            : theme.colorScheme.outline,
                        fontWeight: expiring ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
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
              showDeleted ? kRecycleBinIcon : kEmptyNotesIcon,
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

/// 提示"已删除，可在回收站恢复 N 天"。
///
/// ## 为什么这句话必须存在
///
/// 菜单写的是「删除」（用户熟悉的说法），但实际只做了软删。
/// 如果删完什么都不说，用户会以为数据立刻没了；
/// 而保留期到了被自动清理时，用户又没有任何预警。
/// **不可逆的流程必须在发生前与发生后都能被看见。**
void _notifyMovedToTrash(ScaffoldMessengerState messenger, int retentionDays) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        retentionDays > 0
            ? '笔记已删除。可在回收站中恢复（保留 $retentionDays 天）'
            : '笔记已删除。可在回收站中恢复。',
      ),
      action: SnackBarAction(
        label: '知道了',
        onPressed: () => messenger.hideCurrentSnackBar(),
      ),
    ),
  );
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
