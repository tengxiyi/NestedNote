// SPDX-License-Identifier: AGPL-3.0-or-later
//! 修订历史与对比（铁律 T6 的兑现）。
//!
//! ## 这个功能的价值
//!
//! 我们**一直在写修订记录**（每次保存一条），却只让它躺在数据库里。
//! 把"看到历史列表"升级成"看清改了什么"，是现有能力最直接的一次变现。
//!
//! ## 数据来源说明（重要）
//!
//! 修订的**内容快照**是迁移 `0003` 才开始写的
//! （设计依据 `docs/adr/0001-修订内容用完整快照.md`）。
//! 在那之前产生的修订只有元数据，**没有内容可对比**。
//!
//! 这种情况必须**如实显示**为"此版本没有内容快照"，
//! 而不是显示一个空的差异——空差异会被读成"这两版一样"，
//! 而事实是**我们不知道**。把"未知"呈现为"相同"是会误导人的错误。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/note_providers.dart';
import '../core/revision_providers.dart';
import 'icons.dart';
import 'typography.dart';

/// 修订历史对话框：左侧版本列表，右侧差异。
///
/// 用对话框而不是右栏面板：查看历史是**临时且聚焦**的动作，
/// 用户看完就关。做成常驻面板会永久占掉阅读区宽度，
/// 而那个位置应当留给正文。
Future<void> showRevisionHistory(
  BuildContext context, {
  required String noteId,
  required String noteTitle,
}) => showDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) =>
      _RevisionHistoryDialog(noteId: noteId, noteTitle: noteTitle),
);

class _RevisionHistoryDialog extends ConsumerStatefulWidget {
  const _RevisionHistoryDialog({required this.noteId, required this.noteTitle});

  final String noteId;
  final String noteTitle;

  @override
  ConsumerState<_RevisionHistoryDialog> createState() =>
      _RevisionHistoryDialogState();
}

class _RevisionHistoryDialogState
    extends ConsumerState<_RevisionHistoryDialog> {
  /// 被选中的"新版本"修订（默认是最新一条）。
  String? _newId;

  /// 被选中的"旧版本"修订（默认是第二新的一条）。
  String? _oldId;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<RevisionEntry>> history = ref.watch(
      revisionHistoryProvider(widget.noteId),
    );
    final ThemeData theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(kHistoryIcon, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '修订历史 · ${widget.noteTitle}',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: switch (history) {
                  AsyncLoading() => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  AsyncError(:final Object error) => Center(
                    child: Text('$error', style: theme.textTheme.bodySmall),
                  ),
                  AsyncData(:final List<RevisionEntry> value) => _body(
                    context,
                    // FFI 类型 → 界面模型。放在这里而不是 provider 里，
                    // 是因为 Riverpod 3 对"family 返回自定义 class"推断失败
                    // （见 revisionHistoryProvider 的文档）。
                    value.map(RevisionItem.fromRust).toList(growable: false),
                    theme,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    List<RevisionItem> revisions,
    ThemeData theme,
  ) {
    if (revisions.isEmpty) {
      // 空历史是一条**正常**状态（新笔记没有第二次保存）
      return Center(
        child: Text('这篇笔记还没有历史版本。', style: theme.textTheme.bodyMedium),
      );
    }

    // 默认对比"最新两条"。只有一条时，与它自己比（会显示"无差异"），
    // 这比显示一句"无法对比"更有用——用户能看到这一版的内容。
    final String newest = _newId ?? revisions.first.id;
    final String older =
        _oldId ??
        (revisions.length >= 2 ? revisions[1].id : revisions.first.id);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 260,
          child: _timeline(context, revisions, newest, older, theme),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _diffPane(context, newest, older, theme)),
      ],
    );
  }

  Widget _timeline(
    BuildContext context,
    List<RevisionItem> revisions,
    String newest,
    String older,
    ThemeData theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '共 ${revisions.length} 个版本',
            style: theme.textTheme.labelSmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: revisions.length,
            itemBuilder: (BuildContext context, int index) {
              final RevisionItem item = revisions[index];
              final bool isNew = item.id == newest;
              final bool isOld = item.id == older;
              return InkWell(
                // 点一条即把它设为"新版本"，上一条自动成为"旧版本"——
                // 这是查看历史时最常见的意图，省掉两次点击
                onTap: () => setState(() {
                  _newId = item.id;
                  _oldId = index + 1 < revisions.length
                      ? revisions[index + 1].id
                      : item.id;
                }),
                child: Container(
                  color: isNew
                      ? theme.colorScheme.primaryContainer
                      : isOld
                      ? theme.colorScheme.secondaryContainer
                      : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        index == 0 ? kRevisionLatestIcon : kRevisionIcon,
                        size: 15,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '第 ${item.version} 版',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: isNew ? kEmphasisWeight : null,
                              ),
                            ),
                            Text(
                              formatRevisionTime(item.createdAtMs),
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                      if (isNew)
                        revisionBadge(context, isNew: true)
                      else ...<Widget>[
                        if (isOld) revisionBadge(context, isNew: false),
                        // 恢复入口。**最新一行不提供**——它的内容就是当前
                        // 内容，"恢复"它什么都不会发生（用户先保存了当前
                        // 输入的话，最新一条永远是最新的）。
                        IconButton(
                          tooltip: '恢复到这一版',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(kRestoreIcon, size: 16),
                          onPressed: () => _confirmRestore(item),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        // 两版**任选**对比（M3 特色 1 的一部分）。原来只能"与上一版比"，
        // 但用户的真实问题经常是"现在的和三版之前差多少"。
        // 下拉保留点行快捷方式：点行仍是"设为新版本、上一版做旧版本"。
        Row(
          children: <Widget>[
            Text('对比：', style: theme.textTheme.labelSmall),
            const SizedBox(width: 4),
            _versionPicker(
              context,
              theme,
              label: '旧',
              value: older,
              revisions: revisions,
              excludeId: null,
              onChanged: (String? id) {
                if (id != null) {
                  setState(() => _oldId = id);
                }
              },
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward, size: 12, color: Colors.grey),
            const SizedBox(width: 8),
            _versionPicker(
              context,
              theme,
              label: '新',
              value: newest,
              revisions: revisions,
              excludeId: null,
              onChanged: (String? id) {
                if (id != null) {
                  setState(() => _newId = id);
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _diffPane(
    BuildContext context,
    String newest,
    String older,
    ThemeData theme,
  ) {
    final AsyncValue<DiffResult> diff = ref.watch(
      revisionDiffProvider((widget.noteId, older, newest)),
    );

    return switch (diff) {
      AsyncLoading() => const Center(child: CircularProgressIndicator()),
      AsyncError(:final Object error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('$error', style: theme.textTheme.bodySmall),
        ),
      ),
      AsyncData(:final DiffResult value) => switch (value) {
        DiffMissingSnapshot() => _missingSnapshot(value, theme),
        DiffContent() => _diffLines(value, theme),
      },
    };
  }

  /// 缺快照时**明确说明**，而不是显示空差异。
  Widget _missingSnapshot(DiffMissingSnapshot missing, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.history_toggle_off,
              size: 44,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('无法对比', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              missing.explanation,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _diffLines(DiffContent content, ThemeData theme) {
    if (content.identical) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              content.oldVersion == content.newVersion
                  ? '这是第 ${content.newVersion} 版，没有可比较的前一版。'
                  : '第 ${content.oldVersion} 版与第 ${content.newVersion} 版内容相同。',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: <Widget>[
              Text(
                '第 ${content.oldVersion} 版 → 第 ${content.newVersion} 版',
                style: theme.textTheme.labelLarge,
              ),
              const Spacer(),
              Text(
                '+${content.added}  −${content.removed}',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: content.lines.length,
              itemBuilder: (BuildContext context, int index) =>
                  _DiffRow(line: content.lines[index]),
            ),
          ),
        ),
      ],
    );
  }

  /// 单个版本选择器（"旧"/"新"两个下拉共用）。
  Widget _versionPicker(
    BuildContext context,
    ThemeData theme, {
    required String label,
    required String value,
    required List<RevisionItem> revisions,
    required String? excludeId,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButton<String>(
      value: value,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: theme.textTheme.labelSmall,
      items: <DropdownMenuItem<String>>[
        for (final RevisionItem r in revisions)
          if (r.id != excludeId)
            DropdownMenuItem<String>(
              value: r.id,
              child: Text(
                '$label · 第 ${r.version} 版 · ${formatRevisionTime(r.createdAtMs)}',
              ),
            ),
      ],
      onChanged: onChanged,
    );
  }

  /// 恢复到指定版本。
  ///
  /// ## 流程（每一步都有原因）
  ///
  /// 1. **先保存当前编辑**（若有）：恢复会覆盖文档，未保存的输入若不
  ///    先落盘就真的丢了。保存之后它成为最新修订，恢复只是再追加一条
  ///    ——**链上什么都不丢**；
  /// 2. 取目标版本的快照文本（`null` = 无快照，如实拒绝而不是恢复成空）；
  /// 3. 确认框展示**恢复将造成的差异**（当前 → 目标）——
  ///    "恢复会丢什么"必须先看见（用户确认的三个决策之一）；
  /// 4. 确认后走既有的保存路径（产生一条新修订）；
  /// 5. **重载编辑器**：不重载的话，编辑器的"已保存基准"还是旧文本，
  ///    下次自动保存会把旧内容写回去，恢复等于白做（数据安全，不是刷新）。
  Future<void> _confirmRestore(RevisionItem target) async {
    // 1) 当前输入先落盘（没有编辑器时 saveNow 返回 false，跳过）
    await ref.read(editorSaveChannelProvider.notifier).saveNow();
    if (!mounted) {
      return;
    }

    // 2) 取快照
    final String? snapshotText;
    try {
      snapshotText = await fetchRevisionSnapshot(target.id);
    } on NoteFailure catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure.hint)));
      }
      return;
    }
    if (snapshotText == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这一版没有内容快照，无法恢复。')));
      }
      return;
    }
    if (!mounted) {
      return;
    }

    // 3) 确认（带差异预览）
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RestoreConfirmDialog(noteId: widget.noteId, target: target),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    // 4) 恢复 = 用那一版内容保存一次（标题传 null：内核语义是"不动标题"）
    try {
      await ref
          .read(noteActionsProvider)
          .save(widget.noteId, title: widget.noteTitle, text: snapshotText);
    } on NoteFailure catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure.hint)));
      }
      return;
    }

    // 5) 编辑器重载 + 历史列表刷新（恢复本身产生了一条新修订）
    await ref.read(editorReloadChannelProvider.notifier).reloadNow();
    ref.invalidate(revisionHistoryProvider(widget.noteId));

    if (mounted) {
      Navigator.of(context)
        ..pop() // 关确认框（保险：某些路径没 pop 过）
        ..pop(); // 关历史对话框
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复到第 ${target.version} 版。当前内容仍保留在历史里。')),
      );
    }
  }
}

/// 恢复前的确认框：把"恢复会丢什么"先用差异摆出来。
///
/// ## 为什么预览的差异方向是"当前 → 目标"
///
/// 用户要回答的问题是"**我现在的内容会变成什么**"。因此 diff 的
/// 旧侧是**当前**（最新修订），新侧是**目标版本**：红色行 = 会消失的，
/// 绿色行 = 会回来的。与差异窗格默认的"旧 → 新"阅读方向一致，
/// 但语义必须讲清楚，否则红绿含义会被读反。
class _RestoreConfirmDialog extends ConsumerWidget {
  const _RestoreConfirmDialog({required this.noteId, required this.target});

  final String noteId;
  final RevisionItem target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 当前（最新）修订：历史的第一条。恢复预览 = 当前 → 目标。
    final AsyncValue<List<RevisionEntry>> history = ref.watch(
      revisionHistoryProvider(noteId),
    );
    final String? currentId = history.value?.firstOrNull?.id;

    return AlertDialog(
      title: Text('恢复到第 ${target.version} 版？'),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '恢复后正文会变成该版本的内容。'
              '你当前的内容已经保存进历史，之后随时可以再恢复回来。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '差异预览（当前 → 第 ${target.version} 版）：'
              '红色＝会消失，绿色＝会回来。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 280,
              child: currentId == null
                  ? const Center(child: CircularProgressIndicator())
                  : _restoreDiff(context, ref, currentId, theme),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('恢复这一版'),
        ),
      ],
    );
  }

  Widget _restoreDiff(
    BuildContext context,
    WidgetRef ref,
    String currentId,
    ThemeData theme,
  ) {
    final AsyncValue<DiffResult> diff = ref.watch(
      revisionDiffProvider((noteId, currentId, target.id)),
    );
    return switch (diff) {
      AsyncLoading() => const Center(child: CircularProgressIndicator()),
      AsyncError(:final Object error) => Center(
        child: Text('差异读取失败：$error', style: theme.textTheme.bodySmall),
      ),
      AsyncData(:final DiffResult value) => switch (value) {
        DiffMissingSnapshot() => Text(
          value.explanation,
          style: theme.textTheme.bodySmall,
        ),
        // 无差异也如实显示：说明两版内容本来就一样
        DiffContent() when value.added == 0 && value.removed == 0 => Center(
          child: Text('这一版与当前内容相同。', style: theme.textTheme.bodyMedium),
        ),
        DiffContent() => ListView.builder(
          itemCount: value.lines.length,
          itemBuilder: (BuildContext context, int index) =>
              _DiffRow(line: value.lines[index]),
        ),
      },
    };
  }
}

/// 差异中的一行。
///
/// ## 配色与标记
///
/// 用**绿/红底 + 前景的 `+`/`-` 标记**双重表达（铁律 U 组：不能只靠颜色传达信息）：
/// 色盲用户看不出红绿差别，但看得到 `+`/`-`。
class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color? background = line.isAdded
        ? Colors.green.withValues(alpha: 0.12)
        : line.isRemoved
        ? Colors.red.withValues(alpha: 0.12)
        : null;

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 14,
            child: Text(
              line.isAdded
                  ? '+'
                  : line.isRemoved
                  ? '−'
                  : ' ',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: kEmphasisWeight,
                color: line.isAdded
                    ? Colors.green.shade800
                    : line.isRemoved
                    ? Colors.red.shade800
                    : null,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              line.text.isEmpty ? ' ' : line.text,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 修订时间的显示格式。
///
/// 历史列表里时间要**精确到分钟**：用户是靠"我什么时候改的"来定位版本的，
/// 只显示日期在一天内多次修改时无从区分。
String formatRevisionTime(int utcMs) {
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(utcMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
