// SPDX-License-Identifier: AGPL-3.0-or-later
//! 左栏：笔记本树。
//!
//! ## 三层结构与三种菜单
//!
//! 印象笔记的侧栏是三层：`笔记本(root) → 笔记本组 → 笔记本 → 笔记`。
//! 本项目的层级**没有硬上限**（数据层不限制深度），因此不能照抄"三层"，
//! 而是按**节点能不能再装东西**分两种菜单：
//!
//! | 节点 | 判定 | 菜单差异 |
//! |---|---|---|
//! | **容器**（有子笔记本） | `hasChildren == true` | 可"新建子笔记本"（因为它已经是目录） |
//! | **叶子**（没有子笔记本） | `hasChildren == false` | 可"新建笔记"（它直接装笔记） |
//!
//! 两者共用的项：重命名、删除、移动到、属性。
//!
//! 这个划分比"第 1 层/第 2 层/第 3 层各一套菜单"更稳：
//! 它不依赖绝对深度，用户在任意深度新建子笔记本后菜单依然正确。
//!
//! ## 关于"删除"
//!
//! 菜单写「删除」，语义是**移入回收站**——超过保留期才会被彻底删除。
//! 因此删除后必须提示"在回收站中保留 N 天"。这处文案与语义的差异是刻意的
//! （与主流笔记应用一致），但**不可逆的部分必须可预期**。
//!
//! 三层菜单里都**没有**"彻底删除"：那个入口只在回收站里（见决定 4），
//! 目的是把不可逆操作从日常路径上挪开。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notebook_providers.dart';
import '../core/note_providers.dart';
import '../core/trash_providers.dart';
import 'dialogs.dart';
import 'icons.dart';

/// 每一层笔记本的缩进量（逻辑像素）。
const double kIndentPerLevel = 13;

/// 标签距离左边缘的基础内边距。
const double kIndentBase = 8;

/// 缩进总量上限。左栏宽度可拖动调整，取一个偏保守的值，
/// 保证最窄（`kSidebarMinWidth`）时深层级的名称仍有余量。
const double kIndentMax = 100;

/// 计算某个层级在左栏中的缩进量。///
/// ## 为什么要"封顶"而不是"一直加"
///
/// 层级没有硬上限（数据层不限制深度），但左栏宽度有限。
/// 若无限累加，深层级的名称会被挤出可视区域。
///
/// ## 为什么封顶前必须保证"每层都不同"
///
/// 第一版写成了 `depth.clamp(0, 6) * 14`——**第 7 层开始缩进完全相同**，
/// 于是两个不同层级的兄弟节点看起来一样深，用户无法判断自己在哪一层。
/// 「封顶」应当封的是**总宽度**，而不是**层级的区分度**：
/// 在到达上限之前，每一层都必须给出不同的缩进。
///
/// 提取成独立的纯函数是为了**可测试**：缩进是层级可视化的核心，
/// 而它藏在 widget 里几乎没法断言。
double notebookIndent(int depth) {
  // 负深度不该出现，但真出现了也不能把内容推到屏幕外
  final int safeDepth = depth < 0 ? 0 : depth;
  final double wanted = kIndentBase + (safeDepth * kIndentPerLevel);
  return wanted > kIndentMax ? kIndentMax : wanted;
}

/// 左栏：笔记本树 + 过滤 + 快捷入口。
class NotebookSidebar extends ConsumerStatefulWidget {
  /// 构造。
  const NotebookSidebar({super.key});

  @override
  ConsumerState<NotebookSidebar> createState() => _NotebookSidebarState();
}

class _NotebookSidebarState extends ConsumerState<NotebookSidebar> {
  /// 过滤输入框的控制器。由本组件持有，因为它是纯界面状态。
  final TextEditingController _filter = TextEditingController();

  /// 用于把 F2 重命名绑定到"当前有焦点的树"，而不是全局快捷键。
  final FocusNode _treeFocus = FocusNode(debugLabel: 'notebook-tree');

  @override
  void dispose() {
    _filter.dispose();
    _treeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<NotebookNode>> tree = ref.watch(
      notebooksTreeProvider,
    );
    final List<NotebookNode> visible = ref.watch(filteredNotebookTreeProvider);
    final String keyword = ref.watch(notebookFilterProvider);
    final String? selected = ref.watch(selectedNotebookIdProvider);
    final ThemeData theme = Theme.of(context);

    // "有子节点"决定菜单形态（见文件头说明）。用完整树判断，
    // 而不是过滤后的列表——过滤只影响显示，不该改变节点性质。
    final Set<String> parents = <String>{
      for (final NotebookNode node in tree.value ?? const <NotebookNode>[])
        if (node.parentId != null) node.parentId!,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(theme),
        _filterField(theme),
        const Divider(height: 8),
        // "全部笔记"是一个显式条目，而不是"未选择"的隐含状态——
        // 用户需要能明确地回到"看所有笔记"。
        NotebookTreeTile(
          icon: kAllNotesIcon,
          label: '全部笔记',
          selected: selected == null,
          depth: 0,
          onTap: () => ref.read(selectedNotebookIdProvider.notifier).clear(),
        ),
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
            AsyncData() when visible.isEmpty => Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '没有匹配「$keyword」的笔记本。',
                style: theme.textTheme.bodySmall,
              ),
            ),
            AsyncData() => Focus(
              focusNode: _treeFocus,
              // F2 重命名：仅在树有焦点时生效。
              // 用 CallbackShortcuts 而不是全局 Shortcuts，
              // 否则用户在右栏输入时按 F2 也会触发重命名。
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.f2): () {
                    final String? id = ref.read(selectedNotebookIdProvider);
                    if (id == null) {
                      return;
                    }
                    final NotebookNode? node = _findById(tree.value, id);
                    if (node != null) {
                      _renameNotebook(node);
                    }
                  },
                },
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) {
                    final NotebookNode node = visible[index];
                    return NotebookTreeTile(
                      // 层级用**同一套图标的变体**表达（实心 → 打开 → 轮廓）：
                      // 既看得出"它们是同类"，又分得清"自己在哪一层"。
                      icon: folderIconForDepth(node.depth),
                      label: node.name,
                      // 徽标用 **noteCount**（该目录整棵子树的笔记数）。
                      //
                      // ## 这个位置改过两次，第二次是我想错了
                      //
                      // **第一版**用子树合计。用户说"看不懂 6 是什么"。
                      //
                      // **第二版**改成"只在最底层显示直属数"——那是**错的诊断**。
                      // 真正的问题是**笔记可以挂在中间层**：分类节点里躺着笔记，
                      // 于是"父级有几篇"永远说不清（父级 5、子级 4，两个都对，
                      // 用户却要问"为什么多一个"）。
                      //
                      // **现在**：内核让新建的笔记自动下潜到最底层子目录
                      //（`resolve_note_notebook`），笔记只住在叶子里；
                      // 于是"点父级看整棵子树"不再有歧义，
                      // 徽标用子树合计就成了唯一自然的口径：
                      //
                      //     徽标 = 点进这个目录能看到的行数
                      //
                      // 对每一层都成立，用户不需要理解"直属 / 合计"的区别。
                      trailingCount: node.noteCount,
                      selected: node.id == selected,
                      depth: node.depth,
                      onTap: () {
                        _treeFocus.requestFocus();
                        ref
                            .read(selectedNotebookIdProvider.notifier)
                            .select(node.id);
                      },
                      onLongPress: () => _notebookMenu(
                        node,
                        isContainer: parents.contains(node.id),
                      ),
                    );
                  },
                ),
              ),
            ),
          },
        ),
      ],
    );
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 6, 2),
    child: Row(
      children: <Widget>[
        Text('笔记本', style: theme.textTheme.titleSmall),
        const Spacer(),
        IconButton(
          tooltip: '新建顶层笔记本',
          visualDensity: VisualDensity.compact,
          onPressed: () => _createNotebook(null),
          icon: const Icon(kNewNotebookIcon, size: 20),
        ),
      ],
    ),
  );

  Widget _filterField(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
    child: TextField(
      controller: _filter,
      style: theme.textTheme.bodySmall,
      decoration: InputDecoration(
        isDense: true,
        hintText: '查找笔记本',
        prefixIcon: const Icon(Icons.search, size: 16),
        prefixIconConstraints: const BoxConstraints(minWidth: 28),
        suffixIcon: _filter.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 14),
                onPressed: () {
                  _filter.clear();
                  ref.read(notebookFilterProvider.notifier).clear();
                },
              ),
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
      ),
      onChanged: (String value) =>
          ref.read(notebookFilterProvider.notifier).set(value),
    ),
  );

  /// 长按 / 右键笔记本：按"容器还是叶子"给出不同菜单。
  ///
  /// 用 `showMenu`（真正的上下文菜单）而不是 `showModalBottomSheet`：
  /// 桌面端右键的预期就是在光标处弹出菜单，底部弹出式是移动端的习惯。
  Future<void> _notebookMenu(
    NotebookNode node, {
    required bool isContainer,
  }) async {
    final String? action = await showContextMenu<String>(
      context,
      title: node.name,
      items: <ContextMenuItem<String>>[
        if (isContainer)
          const ContextMenuItem<String>(
            value: 'child',
            label: '新建子笔记本',
            icon: kNewNotebookIcon,
          )
        else
          const ContextMenuItem<String>(
            value: 'note',
            label: '新建笔记',
            icon: kNewNoteIcon,
            shortcut: 'Ctrl+N',
          ),
        const ContextMenuItem<String>.divider(),
        const ContextMenuItem<String>(
          value: 'rename',
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
          shortcut: 'F2',
        ),
        const ContextMenuItem<String>(
          value: 'delete',
          label: '删除',
          icon: kRecycleBinIcon,
          destructive: true,
        ),
        const ContextMenuItem<String>.divider(),
        const ContextMenuItem<String>(
          value: 'move',
          label: '移动到…',
          icon: kMoveIcon,
        ),
        const ContextMenuItem<String>(
          value: 'duplicate',
          label: '创建副本',
          icon: kDuplicateIcon,
        ),
        const ContextMenuItem<String>.divider(),
        const ContextMenuItem<String>(
          value: 'properties',
          label: '属性',
          icon: Icons.info_outline,
        ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'child':
        await _createNotebook(node.id);
      case 'note':
        await _createNoteIn(node);
      case 'rename':
        await _renameNotebook(node);
      case 'duplicate':
        await _duplicateNotebook(node);
      case 'delete':
        await _deleteNotebook(node);
      case 'move':
        await _moveNotebook(node);
      case 'properties':
        await _showProperties(node);
    }
  }

  Future<void> _createNotebook(String? parentId) async {
    final String? name = await promptText(
      context,
      title: parentId == null ? '新建笔记本' : '新建子笔记本',
      hint: '例如：工作 / 项目 A',
    );
    if (name == null || name.trim().isEmpty || !mounted) {
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

  /// 在该笔记本下新建笔记并立即打开。
  Future<void> _createNoteIn(NotebookNode node) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(noteActionsProvider).create(notebookId: node.id);
      ref.read(selectedNotebookIdProvider.notifier).select(node.id);
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  /// 创建副本（递归复制整棵子树）。
  ///
  /// 复制完**提示一句**，告诉用户副本有多少内容——
  /// 一个含几十篇笔记的笔记本被复制时，界面看起来"什么都没发生"，
  /// 用户会以为没成功而反复点。
  Future<void> _duplicateNotebook(NotebookNode node) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(notebookActionsProvider).duplicate(node.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            node.noteCount > 0
                ? '已复制笔记本「${node.name}」及其 ${node.noteCount} 篇笔记。'
                : '已复制笔记本「${node.name}」（没有笔记）。',
          ),
        ),
      );
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _renameNotebook(NotebookNode node) async {
    final String? name = await promptText(
      context,
      title: '重命名笔记本',
      initial: node.name,
      hint: '输入新的名称',
    );
    if (name == null || name.trim().isEmpty || !mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(notebookActionsProvider).rename(node.id, name.trim());
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  /// 删除笔记本。
  ///
  /// 文案用「删除」（与印象笔记一致），但语义是**移入回收站**——
  /// 因此必须同时说明两件事：笔记不会被删、以及保留期。
  Future<void> _deleteNotebook(NotebookNode node) async {
    final int retention = ref.read(trashRetentionDaysProvider).value ?? 0;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('删除笔记本「${node.name}」？'),
        content: Text(
          <String>[
            if (node.noteCount > 0)
              // 明确告知"笔记不会被删"——这是用户最担心的事
              '该笔记本（含子笔记本）中有 ${node.noteCount} 篇笔记。'
                  '笔记不会被删除，只是不再出现在笔记本列表里。'
            else
              '该笔记本下没有笔记。',
            if (retention > 0)
              '\n删除后可在回收站中恢复，保留 $retention 天。'
                  '超过保留期将被自动彻底删除。',
          ].join('\n'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(notebookActionsProvider).delete(node.id);
      _notifyMovedToTrash(messenger, retention, '笔记本');
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  /// 移动到其它笔记本。
  ///
  /// 候选列表**不预先过滤掉自己的后代**——那需要在界面里重算一次子树关系，
  /// 等于把内核已有的环检测抄一遍（铁律 T4）。直接让内核判断，
  /// 把 `WOULD_CREATE_CYCLE` 的提示如实显示。
  Future<void> _moveNotebook(NotebookNode node) async {
    final List<NotebookNode> all =
        ref.read(notebooksTreeProvider).value ?? const <NotebookNode>[];
    // 只排除"自己"：移到自己是明显的无意义操作，提前过滤掉少一次往返
    final List<NotebookNode> candidates = all
        .where((NotebookNode other) => other.id != node.id)
        .toList(growable: false);

    final String? target = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: Text('移动「${node.name}」到'),
        children: <Widget>[
          SimpleDialogOption(
            // 空串表示"移到顶层"；null 表示"用户取消"——
            // 两者必须区分，否则无法表达"移到顶层"这个合法操作
            onPressed: () => Navigator.of(dialogContext).pop(''),
            child: const Text('（顶层）'),
          ),
          for (final NotebookNode other in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(other.id),
              child: Padding(
                padding: EdgeInsets.only(left: notebookIndent(other.depth)),
                child: Text(other.name, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(notebookActionsProvider)
          .move(node.id, target.isEmpty ? null : target);
    } on NoteFailure catch (failure) {
      // WOULD_CREATE_CYCLE 会走到这里，提示由内核给出（"请选择另一个位置…"）
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
    }
  }

  Future<void> _showProperties(NotebookNode node) async {
    final List<NotebookNode> all =
        ref.read(notebooksTreeProvider).value ?? const <NotebookNode>[];
    final String? parentName = node.parentId == null
        ? null
        : all
              .where((NotebookNode other) => other.id == node.parentId)
              .map((NotebookNode other) => other.name)
              .firstOrNull;
    final int depth = node.depth;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(node.name),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _propertyRow('类型', depth == 0 ? '顶层笔记本' : '子笔记本'),
            _propertyRow('层级', '第 ${depth + 1} 层'),
            _propertyRow('上级', parentName ?? '（无）'),
            _propertyRow('笔记数', '${node.noteCount} 篇（含子笔记本）'),
            _propertyRow('标识', node.id),
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
        width: 64,
        child: Text(label, style: const TextStyle(color: Colors.grey)),
      ),
      Expanded(child: SelectableText(value)),
    ],
  ),
);

/// 在树里按 id 找节点。
NotebookNode? _findById(List<NotebookNode>? nodes, String id) {
  for (final NotebookNode node in nodes ?? const <NotebookNode>[]) {
    if (node.id == id) {
      return node;
    }
  }
  return null;
}

/// 提示"已删除，可在回收站恢复 N 天"。
///
/// ## 为什么这句话必须存在
///
/// 菜单写的是「删除」（用户熟悉的说法），但实际只做了软删。
/// 如果删完什么都不说，用户会以为数据立刻没了；
/// 而如果保留期到了被自动清理，用户又没有任何预警。
/// **不可逆的操作必须在发生前与发生后都能被看见。**
void _notifyMovedToTrash(
  ScaffoldMessengerState messenger,
  int retentionDays,
  String what,
) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        retentionDays > 0
            ? '$what已删除。可在回收站中恢复（保留 $retentionDays 天）'
            : '$what已删除。可在回收站中恢复。',
      ),
      action: SnackBarAction(
        label: '知道了',
        onPressed: () => messenger.hideCurrentSnackBar(),
      ),
    ),
  );
}

/// 左栏树中的一行。
///
/// 公开（非下划线开头）以便测试按部件定位并断言其图标——
/// 层级图标是"多层级可视化"的核心，而用 `find.ancestor(byType(Row))`
/// 这类按容器定位的写法会命中整棵树的 Row，取到别的图标。
class NotebookTreeTile extends StatelessWidget {
  /// 构造。
  const NotebookTreeTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.depth,
    required this.onTap,
    this.trailingCount,
    this.onLongPress,
    super.key,
  });

  /// 图标。
  final IconData icon;

  /// 名称。
  final String label;

  /// 是否选中。
  final bool selected;

  /// 层级深度。
  final int depth;

  /// 点击。
  final VoidCallback onTap;

  /// 右侧计数（0 不显示）。
  final int? trailingCount;

  /// 长按 / 右键。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double indent = notebookIndent(depth);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      // 桌面端右键与长按等价：鼠标用户不会去长按
      onSecondaryTap: onLongPress,
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
