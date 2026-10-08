// SPDX-License-Identifier: AGPL-3.0-or-later
//! 中栏：当前笔记本下的笔记列表。
//!
//! ## 职责边界
//!
//! 中栏**只**负责"当前过滤条件下的笔记列表"。它不关心树的形状，
//! 也不渲染笔记内容。因此切换笔记本时只有这里与右栏需要重建。
//!
//! ## 回收站视图的三处特殊处理
//!
//! 1. 展示**全部**笔记本的已删除笔记，而不是"当前笔记本里的已删除笔记"——
//!    否则用户会以为"只删了当前笔记本里的"，找不到别处删的东西。
//! 2. 每行显示**剩余保留天数**。删除是不可逆流程的起点，
//!    用户必须能看见倒计时（见 `core/trash_providers.dart`）。
//! 3. **可多选批量彻底删除**，并且**列出已删除的目录**——
//!    目录同样能被删除，而它曾经完全没有恢复入口，
//!    用户把它删掉后就再也找不回来了（见 `trashedNotebooksProvider`）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notebook_providers.dart';
import '../core/note_providers.dart';
import '../core/trash_providers.dart';
import 'dialogs.dart';
import 'icons.dart';
import 'note_actions.dart';
import 'typography.dart';

/// 中栏：当前笔记本下的笔记列表。
class NoteListPane extends ConsumerStatefulWidget {
  /// 构造。
  const NoteListPane({
    required this.showDeleted,
    required this.openNote,
    required this.onOpenNote,
    super.key,
  });

  /// 是否显示回收站内容。
  final bool showDeleted;

  /// 当前打开的笔记（高亮）。
  final NoteItem? openNote;

  /// 打开某篇笔记（或关闭：传 null）。
  final ValueChanged<NoteItem?> onOpenNote;

  @override
  ConsumerState<NoteListPane> createState() => _NoteListPaneState();
}

class _NoteListPaneState extends ConsumerState<NoteListPane> {
  /// 回收站中已勾选的笔记。
  ///
  /// ## 为什么是本地状态而不是 provider
  ///
  /// 勾选是**纯界面状态**：退出回收站就该忘掉。放进 provider 会带来
  /// "离开后又回来，上次勾的还在"这种惊吓——而勾选意味着**不可逆删除**，
  /// 让用户看到一批他没主动选的、即将被销毁的条目是最糟的体验。
  final Set<String> _selected = <String>{};

  /// 是否处于多选模式。
  ///
  /// 与"勾了几条"分开：多选模式下**允许勾 0 条**，否则用户
  /// 取消最后一条勾选时模式会意外退出。
  bool _selecting = false;

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? notebookId = ref.watch(selectedNotebookIdProvider);
    final String? notebookName = ref.watch(selectedNotebookNameProvider);
    final NoteListQuery query = NoteListQuery(
      // 回收站视图展示**全部**笔记本的已删除笔记，
      // 否则用户会以为"只删了当前笔记本里的"
      notebookId: widget.showDeleted ? null : notebookId,
      includeDeleted: widget.showDeleted,
    );
    // 用**合并视图**而不是原始查询结果：刚保存过的笔记会在这里被叠加，
    // 因此保存时列表不重查、不重排 → 中栏不闪、滚动位置不跳。
    final AsyncValue<List<NoteItem>> notes = ref.watch(
      noteListMergedProvider(query),
    );
    final ThemeData theme = Theme.of(context);
    final int retention = ref.watch(trashRetentionDaysProvider).value ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showDeleted && _selecting)
          _selectionBar(notes.value ?? const <NoteItem>[], theme)
        else
          _header(context, notes, notebookName, notebookId, theme),
        const Divider(height: 1),
        Expanded(
          // ## 回收站是一条**按删除时间排的混合列表**
          //
          // 目录曾经被单独钉在顶部。用户指出这不合理：
          //
          //   > 回收站里面，目录级别的为什么要给它置顶？这个设定不合理
          //
          // 他是对的。用户找东西的依据是**时间**（"我刚删的那个在哪"），
          // 不是**类型**。按类型分组把一条时间线切成两段，于是"刚删的笔记"
          // 可能排在一小时前删的目录下面。
          //
          // 现在笔记与目录混在同一条时间线上，删除时间新的在上——
          // 也就是"最近删的在最上面"，与用户的心智一致。
          //
          // 多选模式下只列**笔记**：目录的彻底删除有自己的依赖顺序
          //（自底向上，见 `purge_notebook` 的说明），不能和笔记一起批删。
          child: widget.showDeleted && !_selecting
              ? _TimelineView(
                  notes: notes,
                  openNote: widget.openNote,
                  retentionDays: retention,
                  onOpenNote: widget.onOpenNote,
                  onEnterSelection: (String id) => setState(() {
                    _selecting = true;
                    _selected.add(id);
                  }),
                )
              : _plainList(context, notes, retention, theme),
        ),
      ],
    );
  }

  /// 普通列表（非回收站，或回收站的多选模式）。
  Widget _plainList(
    BuildContext context,
    AsyncValue<List<NoteItem>> notes,
    int retention,
    ThemeData theme,
  ) {
    return switch (notes) {
      AsyncLoading() => const Center(child: CircularProgressIndicator()),
      AsyncError(:final Object error) => Padding(
        padding: const EdgeInsets.all(14),
        child: Text('$error', style: theme.textTheme.bodySmall),
      ),
      AsyncData(:final List<NoteItem> value) when value.isEmpty =>
        _EmptyNoteList(showDeleted: widget.showDeleted),
      AsyncData(:final List<NoteItem> value) => ListView.builder(
        itemCount: value.length,
        itemBuilder: (BuildContext context, int index) {
          final NoteItem note = value[index];
          return _NoteRow(
            note: note,
            selected: note.id == widget.openNote?.id,
            retentionDays: widget.showDeleted ? retention : null,
            // 多选模式下显示勾选框，点击即勾选（而不是打开笔记）
            selectable: widget.showDeleted && _selecting,
            checked: _selected.contains(note.id),
            onTap: () {
              if (widget.showDeleted && _selecting) {
                _toggle(note.id);
              } else {
                widget.onOpenNote(note);
              }
            },
            onLongPress: () {
              if (widget.showDeleted) {
                // 长按进入多选并勾上这一条——这是移动端与桌面端
                // 都通行的"批量选择"起手式，比先找一个"选择"按钮快
                setState(() {
                  _selecting = true;
                  _selected.add(note.id);
                });
              } else {
                _noteMenu(context, note, retention);
              }
            },
          );
        },
      ),
    };
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) {
        _selected.add(id);
      }
    });
  }

  /// 多选模式下顶部的操作条。
  Widget _selectionBar(List<NoteItem> visible, ThemeData theme) {
    // 只统计**当前列表里**勾中的：切走再回来时列表可能变了，
    // 留着已被过滤掉的 id 会让"已选 3 条"与实际可见的对不上。
    final Set<String> visibleIds = visible.map((NoteItem n) => n.id).toSet();
    final int count = _selected.intersection(visibleIds).length;
    final bool allSelected = visible.isNotEmpty && count == visibleIds.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '退出多选',
            visualDensity: VisualDensity.compact,
            onPressed: _exitSelection,
            icon: const Icon(Icons.close, size: 20),
          ),
          Expanded(
            child: Text('已选 $count 条', style: theme.textTheme.titleSmall),
          ),
          TextButton(
            onPressed: visible.isEmpty
                ? null
                : () => setState(() {
                    if (allSelected) {
                      _selected.removeAll(visibleIds);
                    } else {
                      _selected.addAll(visibleIds);
                    }
                  }),
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
          const SizedBox(width: 4),
          FilledButton.tonal(
            // 一条都没勾时禁用，而不是弹一个"请先选择"——
            // 按钮变灰本身就说明了原因，少一次打断。
            onPressed: count == 0
                ? null
                : () => _purgeSelected(_selected.intersection(visibleIds)),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer,
            ),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
  }

  /// 批量彻底删除，**一次确认**，然后如实回报逐条结果。
  Future<void> _purgeSelected(Set<String> ids) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: '彻底删除 ${ids.length} 条？',
      message:
          '这些笔记将被**永久删除**，无法恢复。\n\n'
          '如果只是想清空位置，可以先不用管——它们会在保留期结束后自动删除。',
      confirmLabel: '彻底删除',
    );
    if (!confirmed || !mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final BatchPurgeOutcome outcome = await ref
          .read(trashActionsProvider)
          .purgeMany(ids.toList());
      if (!mounted) {
        return;
      }
      // 部分成功时**保留**失败的那些勾选，让用户能立刻看到还剩什么没删、
      // 再决定怎么办。全部成功才清空并退出多选。
      setState(() {
        if (outcome.allSucceeded) {
          _exitSelection();
          return;
        }
        // 成功删掉的从勾选里移除；失败的留着——
        // 界面上它们还在列表里，勾选也就该还在，否则用户会以为
        // "我勾了 5 条，删完一条都没勾，是不是都没删？"
        _selected.removeAll(ids);
        // 凑巧全部失败时至少要留下点什么可操作：保持多选模式即
        // 让用户能直接重试或取消。
      });
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(outcome.summary),
        ),
      );
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Widget _header(
    BuildContext context,
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
                  widget.showDeleted ? '回收站' : (notebookName ?? '全部笔记'),
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
            tooltip: widget.showDeleted ? '回收站中不能新建' : '在此新建笔记',
            visualDensity: VisualDensity.compact,
            // 回收站里除了"新建"，还提供**进入多选**的入口。
            // 长按也能进，但桌面用户习惯找按钮，两个都给。
            onPressed: widget.showDeleted
                ? () => setState(() => _selecting = true)
                : () => _createNote(context, notebookId),
            icon: Icon(
              widget.showDeleted ? Icons.checklist : kNewNoteIcon,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createNote(BuildContext context, String? notebookId) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final CreatedNote created = await ref
          .read(noteActionsProvider)
          .create(notebookId: notebookId);

      // 左栏选中项**跟到笔记实际落地的目录**。
      //
      // 内核规定"笔记只住在最底层目录"：用户在非最底层目录点新建时，
      // 笔记会被下潜到排序第 1 的最底层子目录。若不跟随，
      // 用户会看到"我在这里点的，笔记却出现在别处"（实际是混在
      // 整棵子树的列表里），比"没反应"更让人困惑。
      final String? landed = created.notebookId;
      if (landed != null && landed != notebookId) {
        ref.read(selectedNotebookIdProvider.notifier).select(landed);
      }
      // 新建后立刻打开它。摘要从"刚保存过的覆盖层"里取——内核只回了 id，
      // 而打开需要的是摘要对象（见 NotesPage._openNote 的说明）。
      final NoteItem? fresh = ref
          .read(noteListMergedProvider(const NoteListQuery()))
          .value
          ?.where((NoteItem n) => n.id == created.id)
          .firstOrNull;
      if (fresh != null) {
        widget.onOpenNote(fresh);
      }
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
    NoteItem note,
    int retention,
  ) async {
    final List<ContextMenuItem<String>> items = widget.showDeleted
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

    // 这些动作**与菜单栏的「笔记」菜单共用同一批函数**
    //（`note_actions.dart`）。在这里重写一遍会让"删除要提示去回收站"
    // 这类规则出现两份，改一处漏一处。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'open':
          widget.onOpenNote(note);
        case 'restore':
          await ref.read(noteActionsProvider).restore(note.id);
        case 'purge':
          await _purgeNote(context, ref, note);
        case 'delete':
          await deleteNote(context, ref, note);
          // 删掉正在看的那篇就要关掉右栏，否则会继续显示一篇已删除的笔记
          if (widget.openNote?.id == note.id) {
            widget.onOpenNote(null);
          }
        case 'move':
          await moveNote(context, ref, note);
        case 'tags':
          await editNoteTags(context, ref, note);
        case 'duplicate':
          await duplicateNote(
            context,
            ref,
            note,
            onOpen: (String id) {
              final NoteItem? copy = ref
                  .read(noteListMergedProvider(const NoteListQuery()))
                  .value
                  ?.where((NoteItem n) => n.id == id)
                  .firstOrNull;
              if (copy != null) {
                widget.onOpenNote(copy);
              }
            },
          );
        case 'properties':
          await showNoteProperties(context, ref, note);
      }
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
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
      if (widget.openNote?.id == note.id) {
        widget.onOpenNote(null);
      }
      messenger.showSnackBar(const SnackBar(content: Text('已彻底删除。')));
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }
}

/// 中栏的一行笔记。
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.retentionDays,
    this.selectable = false,
    this.checked = false,
  });

  final NoteItem note;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 非 null 时显示"还剩 N 天"（回收站视图用）。
  final int? retentionDays;

  /// 是否处于多选模式（左侧显示勾选框）。
  final bool selectable;

  /// 是否已勾选。
  final bool checked;

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
        // 多选模式下已勾选的行用一层淡色铺底，与"当前打开的笔记"
        // 用**不同的视觉通道**：一个是背景色块（打开），
        // 一个是勾选框（选中）。两者同时存在时用户能分辨。
        color: selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (selectable) ...<Widget>[
                  // 勾选框而不是"整行变色"：不可逆删除需要一个
                  // **明确的、可复核的**选中标记。整行变色在密集列表里
                  // 容易看漏一条，而勾选框一眼能数清。
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: checked,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (_) => onTap(),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
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
                      fontWeight: kEmphasisWeight,
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
                        fontWeight: expiring ? kEmphasisWeight : null,
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

/// 回收站的**时间线视图**：笔记与目录按**删除时间**混排。
///
/// ## 为什么不再按类型分组
///
/// 最初目录被单独钉在列表顶部，用户指出这不合理：
///
/// > 回收站里面，目录级别的为什么要给它置顶？这个设定不合理
///
/// 他是对的。用户找东西的依据是**时间**（"我刚删的那个在哪"），
/// 不是**类型**。按类型分组把一条时间线切成两段，于是"刚删的笔记"
/// 可能排在一小时前删的目录下面。
///
/// 现在混排，删除时间新的在上——正好对应"最近删的在最上面"。
///
/// ## 排序键用 `deletedAtMs` 而不是 `updatedAtMs`
///
/// 这两个值在删除之后就不同步了（一篇三天前写、今天删的笔记，
/// `updatedAtMs` 是三天前）。用错会让"最近删的"沉到列表中间。
class _TimelineView extends ConsumerWidget {
  const _TimelineView({
    required this.notes,
    required this.openNote,
    required this.retentionDays,
    required this.onOpenNote,
    required this.onEnterSelection,
  });

  final AsyncValue<List<NoteItem>> notes;
  final NoteItem? openNote;
  final int retentionDays;
  final ValueChanged<NoteItem?> onOpenNote;
  final ValueChanged<String> onEnterSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<TrashedNotebookItem>> trashed = ref.watch(
      trashedNotebooksProvider,
    );
    final ThemeData theme = Theme.of(context);

    if (notes case AsyncError(:final Object error)) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('$error', style: theme.textTheme.bodySmall),
      );
    }
    if (notes is AsyncLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final List<NoteItem> noteList = notes.value ?? const <NoteItem>[];
    final List<TrashedNotebookItem> bookList =
        trashed.value ?? const <TrashedNotebookItem>[];

    // 合并成一条时间线。用记录类型而不是新建一个类：这里只需要
    // "按时间排好序、渲染时能分辨两种"这两件事，加一个类反而要维护
    // 一份与两个真实类型重复的字段清单。
    final List<({int at, NoteItem? note, TrashedNotebookItem? book})> items =
        <({int at, NoteItem? note, TrashedNotebookItem? book})>[
          for (final NoteItem n in noteList)
            // 未删除的笔记不该出现在这里；真出现了用它自己的时间兜底，
            // 而不是丢掉它（丢掉就是"列表里少了一条"）。
            (at: n.deletedAtMs ?? n.updatedAtMs, note: n, book: null),
          for (final TrashedNotebookItem b in bookList)
            (at: b.deletedAtMs, note: null, book: b),
        ]..sort(
          (
            ({int at, NoteItem? note, TrashedNotebookItem? book}) a,
            ({int at, NoteItem? note, TrashedNotebookItem? book}) b,
          ) => b.at.compareTo(a.at),
        );

    if (items.isEmpty) {
      return const _EmptyNoteList(showDeleted: true);
    }

    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final ({int at, NoteItem? note, TrashedNotebookItem? book}) item =
            items[index];
        final TrashedNotebookItem? book = item.book;
        if (book != null) {
          return _TrashedNotebookRow(item: book, retentionDays: retentionDays);
        }
        final NoteItem note = item.note!;
        return _NoteRow(
          note: note,
          selected: note.id == openNote?.id,
          retentionDays: retentionDays,
          onTap: () => onOpenNote(note),
          // 长按进入多选（与网格列表一致的手势）
          onLongPress: () => onEnterSelection(note.id),
        );
      },
    );
  }
}

/// 回收站里的一个目录（一行）。
class _TrashedNotebookRow extends ConsumerWidget {
  const _TrashedNotebookRow({required this.item, required this.retentionDays});

  final TrashedNotebookItem item;
  final int retentionDays;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final TrashAge age = trashAgeOf(
      deletedAtMs: item.deletedAtMs,
      retentionDays: retentionDays,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          // 目录图标：与左栏**同一套**（规则 1/2），一眼看出这是目录不是笔记。
          // 回收站里层级关系不重要（父目录可能也删了），因此固定用第一层的
          // 变体，不做深度区分——否则一个已删子目录会显示成"打开的书包"，
          // 反而让人以为它还在树里某个确定位置。
          const Icon(kNotebookRootIcon, size: 15),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  age.expired ? '已过期，下次启动将清理' : '还剩 ${age.remainingDays} 天',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: age.expired
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _restore(context, ref),
            child: const Text('恢复'),
          ),
          IconButton(
            tooltip: '彻底删除这个目录',
            visualDensity: VisualDensity.compact,
            onPressed: () => _purge(context, ref),
            icon: Icon(
              kRecycleBinIcon,
              size: 18,
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(trashActionsProvider).restoreNotebook(item.id);
      messenger.showSnackBar(
        SnackBar(content: Text('已恢复目录「${item.name}」及其子目录。')),
      );
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  /// 彻底删除一个目录。
  ///
  /// ## 为什么失败是常态，而且必须如实说
  ///
  /// 内核会拒绝两种情形：
  ///
  /// 1. 目录里还有**没删除的笔记**——删下去就会销毁用户还在用的内容；
  /// 2. 目录在树里**还有子目录**——这是外键限制，必须先删子目录。
  ///
  /// 第二种对用户来说很费解（"我明明删了整个目录"），因此提示里要
  /// 说清下一步怎么办，而不是只报一句"操作失败"。
  Future<void> _purge(BuildContext context, WidgetRef ref) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: '彻底删除目录「${item.name}」？',
      message:
          '这个目录连同它在回收站里的笔记会被**永久删除**，无法恢复。\n\n'
          '如果目录里还有没删除的笔记，或它下面还有子目录，'
          '系统会拒绝——那说明有东西还挂在它下面。',
      confirmLabel: '彻底删除',
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(trashActionsProvider).purgeNotebook(item.id);
      messenger.showSnackBar(SnackBar(content: Text('已彻底删除目录「${item.name}」。')));
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
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

/// 把 UTC 毫秒格式化成**精确到分钟**的完整时间。
///
/// 与 [formatListTime] 的分工：
///
/// - [formatListTime] 为**列表**服务——列表要的是"多久以前"的粗略感，
///   所以"今天"只显示时间、往年只显示日期，省横向空间；
/// - 本函数为**属性对话框**服务——那里要的是**确切时刻**。
///   用户打开属性多半是在核对"这篇到底什么时候改的"，
///   给他"今天 11:28"是不够的（跨天就失去意义）。
///
/// 公开（非下划线开头）是为了能在测试里直接断言格式。
String formatAbsoluteTime(int utcMs) {
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(utcMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
