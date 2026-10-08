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
import '../core/layout_providers.dart';
import '../core/note_providers.dart';
import 'icons.dart';
import 'menu_bar.dart';
import 'note_editor_page.dart';
import 'note_list_pane.dart';
import 'notebook_sidebar.dart';

/// 左栏默认宽度。
const double kSidebarWidth = 232;

/// 左栏宽度下限（再窄就放不下名称了）。
const double kSidebarMinWidth = 150;

/// 左栏宽度上限。
const double kSidebarMaxWidth = 420;

/// 中栏默认宽度。
const double kNoteListWidth = 300;

/// 中栏宽度下限。
const double kNoteListMinWidth = 200;

/// 中栏宽度上限。
const double kNoteListMaxWidth = 480;

/// 右栏（阅读区）的最小宽度。
///
/// 拖动左栏或中栏时，至少给右栏留这么多——否则用户能把内容区挤到 0 宽，
/// 然后以为"笔记打开后是空白的"。
const double kReadingPaneMinWidth = 260;

/// 分栏拖动条的**可拖动宽度**。
///
/// 刻意比视觉宽度（1–3 逻辑像素）大得多：一条 1 像素的线用鼠标几乎抓不住。
/// 这是桌面应用里很常见的可用性问题——看得见但点不中。
const double kSplitterHitWidth = 8;

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

  @override
  Widget build(BuildContext context) {
    final AsyncValue<EngineStatus> engine = ref.watch(engineProvider);
    // 左栏折叠与三栏模式都放进 provider，好让菜单与快捷键能改它们。
    // 留在 State 里的话，菜单项得持有一个 State 引用才能改——
    // 那是把"界面状态"与"谁持有它"绑在一起，很快会变成互相引用。
    final bool sidebarCollapsed = ref.watch(sidebarCollapsedProvider);
    final PaneLayout layout = ref.watch(paneLayoutProvider);
    // 当前打开的笔记也放进 provider：菜单栏的「笔记」菜单要按它决定
    // 哪些项可用，以及确认文案里的标题。
    final NoteItem? openNote = ref.watch(openNoteProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(engine.value?.displayName ?? '拾光笔记'),
        titleSpacing: 4,
        leading: IconButton(
          tooltip: sidebarCollapsed ? '展开笔记本栏' : '折叠笔记本栏',
          onPressed: () => ref.read(sidebarCollapsedProvider.notifier).toggle(),
          icon: Icon(
            sidebarCollapsed ? kExpandSidebarIcon : kCollapseSidebarIcon,
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: _showDeleted ? '隐藏回收站' : '显示回收站',
            onPressed: () => setState(() => _showDeleted = !_showDeleted),
            icon: Icon(
              // 开关的"开/关"用同一套图标的变体表达（轮廓 → 实心）
              _showDeleted ? kRecycleBinActiveIcon : kRecycleBinIcon,
              color: _showDeleted
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
          IconButton(
            tooltip: '引擎自检',
            onPressed: () => _showDiagnostics(context),
            icon: const Icon(kDiagnosticsIcon),
          ),
        ],
      ),
      body: switch (engine) {
        AsyncError(:final Object error) => _FailureView(message: '$error'),
        AsyncData() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 菜单栏放在 AppBar 之下、三栏之上：这样它是**跨三栏**的，
            // 与用户确认的形态一致（印象笔记也是这个位置）。
            const AppMenuBar(),
            const Divider(height: 1),
            Expanded(
              child: _ThreePane(
                showDeleted: _showDeleted,
                sidebarCollapsed: sidebarCollapsed,
                layout: layout,
                openNote: openNote,
                onOpenNote: _openNote,
              ),
            ),
          ],
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  /// 打开/关闭笔记。
  ///
  /// `null` 表示关闭——菜单里的「关闭当前笔记」与列表取消选中都走这里。
  ///
  /// ## 为什么接收整个 [NoteItem] 而不是 id
  ///
  /// 第一版接收 id，然后在这里 `ref.read(noteListMergedProvider(...))`
  /// 回查摘要。两个问题：
  ///
  /// 1. **回查的 provider 可能还没被建立**。`read` 一个从未被 `watch`
  ///    过的 family provider，首次拿到的是 loading 态（`value == null`），
  ///    于是查不到笔记、点击毫无反应——这个缺陷就是测试抓出来的；
  /// 2. 列表本来就已经持有那个对象，"传 id 再查回来"是无谓的往返。
  ///
  /// 改成直接传对象：调用方给什么就打开什么，没有中间态。
  void _openNote(NoteItem? note) {
    final OpenNote notifier = ref.read(openNoteProvider.notifier);
    if (note == null) {
      notifier.close();
    } else {
      notifier.open(note);
    }
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
                      check.passed ? kCheckIcon : kErrorIcon,
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

/// 三栏容器 —— 三栏宽度**均可拖动调整**。
///
/// ## 宽度规则
///
/// - 左栏与中栏由用户拖动决定宽度，各自有最小/最大值
/// - 右栏吃掉剩余空间（它是内容区，本来就该占据最大份额）
/// - 拖动左栏分隔条时，上限由"右栏至少留 [kReadingPaneMinWidth]"决定——
///   否则用户可以把右栏挤到 0 宽，然后以为"笔记不见了"
class _ThreePane extends StatefulWidget {
  const _ThreePane({
    required this.showDeleted,
    required this.sidebarCollapsed,
    required this.layout,
    required this.openNote,
    required this.onOpenNote,
  });

  final bool showDeleted;
  final bool sidebarCollapsed;
  final PaneLayout layout;
  final NoteItem? openNote;
  final ValueChanged<NoteItem?> onOpenNote;

  @override
  State<_ThreePane> createState() => _ThreePaneState();
}

class _ThreePaneState extends State<_ThreePane> {
  /// 左栏宽度。
  double _sidebarWidth = kSidebarWidth;

  /// 中栏宽度。
  double _listWidth = kNoteListWidth;

  @override
  Widget build(BuildContext context) {
    // 拖动到底时不要把右栏挤没：给它留一个下限
    void dragSidebar(double delta) {
      setState(() {
        _sidebarWidth = (_sidebarWidth + delta).clamp(
          kSidebarMinWidth,
          kSidebarMaxWidth,
        );
      });
    }

    void dragList(double delta) {
      setState(() {
        _listWidth = (_listWidth + delta).clamp(
          kNoteListMinWidth,
          kNoteListMaxWidth,
        );
      });
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        // 显示模式决定**哪几栏参与布局**。
        //
        // 隐藏的栏不是"宽度设成 0"，而是**根本不放进 Row**——
        // 留一个 0 宽的子项会连带留下它的分隔条，用户会看到一个
        // 拖不动的细线。这不只是洁癖：那根线看起来像 bug。
        final bool sidebarVisible =
            !widget.sidebarCollapsed && widget.layout != PaneLayout.editorOnly;
        final bool listVisible = widget.layout != PaneLayout.editorOnly;
        final bool editorVisible = widget.layout != PaneLayout.listOnly;

        // 分隔条的命中宽度是可拖动的，因此也要从可用宽度里扣掉。
        // 只算**实际显示**的分隔条。
        int splitterCount = 0;
        if (sidebarVisible && listVisible) {
          splitterCount++;
        }
        if (listVisible && editorVisible) {
          splitterCount++;
        }
        final double chrome = kSplitterHitWidth * splitterCount;

        // 只看列表时没有编辑器，就不必给正文留最小宽度
        final double reserveForEditor = editorVisible
            ? kReadingPaneMinWidth
            : 0;
        final double budget = (available - reserveForEditor - chrome).clamp(
          0.0,
          double.infinity,
        );

        double sidebar = sidebarVisible ? _sidebarWidth : 0;
        double list = listVisible ? _listWidth : 0;

        // 超过预算时按比例压缩（保持两栏的相对关系，而不是把某一栏压到最小）
        final double used = sidebar + list;
        if (used > budget && used > 0) {
          final double scale = budget / used;
          sidebar *= scale;
          list *= scale;
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (sidebarVisible) ...<Widget>[
              SizedBox(width: sidebar, child: const NotebookSidebar()),
              PaneSplitter(tooltip: '拖动调整笔记本栏宽度', onDrag: dragSidebar),
            ],
            if (listVisible) ...<Widget>[
              SizedBox(
                width: list,
                child: NoteListPane(
                  showDeleted: widget.showDeleted,
                  openNote: widget.openNote,
                  onOpenNote: widget.onOpenNote,
                ),
              ),
              // 编辑器也显示时才有东西可拖：没有它，这根分隔条拖不动任何东西
              if (editorVisible)
                PaneSplitter(tooltip: '拖动调整笔记列表宽度', onDrag: dragList),
            ],
            if (editorVisible)
              Expanded(
                child: widget.openNote == null
                    ? const _EmptyReadingPane()
                    : NoteEditorPane(
                        // key 让"切换到另一篇笔记"时重建编辑状态，
                        // 否则会沿用上一篇的文本与"已保存"基准
                        key: ValueKey<String>(widget.openNote!.id),
                        noteId: widget.openNote!.id,
                      ),
              ),
          ],
        );
      },
    );
  }
}

/// 分栏拖动条。
///
/// ## 交互细节（都是有意的）
///
/// - **命中区域比视觉宽度大**：视觉上是一条细线，但可拖动区域宽 [kSplitterHitWidth]。
///   1 像素的线用鼠标几乎抓不住，这是桌面应用很常见的可用性问题。
/// - **悬停时变粗并高亮**：告诉用户"这里可以拖"。
/// - **光标变成左右调整形状**：桌面端最直接的"可拖动"提示。
class PaneSplitter extends StatefulWidget {
  /// 构造。
  const PaneSplitter({required this.onDrag, this.tooltip, super.key});

  /// 拖动回调，参数是水平位移（逻辑像素）。
  final ValueChanged<double> onDrag;

  /// 悬停提示。
  final String? tooltip;

  @override
  State<PaneSplitter> createState() => _PaneSplitterState();
}

class _PaneSplitterState extends State<PaneSplitter> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool active = _hovered || _dragging;

    final Widget bar = MouseRegion(
      // 竖向分栏用系统的"左右调整"光标：Windows 上是标准的左右箭头，
      // 用户一眼就知道这里能拖。不必自定义光标图像。
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            widget.onDrag(details.delta.dx),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        child: SizedBox(
          width: kSplitterHitWidth,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 1,
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip == null) {
      return bar;
    }
    return Tooltip(message: widget.tooltip!, child: bar);
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
            kEmptyReadingIcon,
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
            Icon(kErrorIcon, size: 48, color: theme.colorScheme.error),
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
