// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记列表页 —— 应用主界面。
//!
//! ## 这个页面为什么现在才有
//!
//! P0 的首页是"引擎自检页"，用来验收 Dart ↔ Rust 链路是否打通。
//! 那个页面只能证明内核起来了，不能证明**笔记功能可用**。
//! 本页补上这条闭环：新建 → 列表 → 编辑 → 保存 → 重启后仍在。
//!
//! ## 分层
//!
//! 本文件只做展示与交互，不直接调用 FFI（铁律 A2）。
//! 所有数据来自 `core/note_providers.dart`，写操作走 `NoteActions`。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine.dart';
import '../core/engine_providers.dart';
import '../core/note_providers.dart';
import 'note_editor_page.dart';

/// 笔记列表页。
class NotesPage extends ConsumerStatefulWidget {
  /// 构造。
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  /// 是否显示回收站内容。
  bool _showDeleted = false;

  /// 上一次成功加载的笔记数（用于写入诊断文件）。
  int? _lastLoadedCount;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<EngineStatus> engine = ref.watch(engineProvider);
    // 写入诊断：让"应用到底看到了什么"可被外部核实，而不必依赖界面观察。
    // 见 engine_providers.dart 中关于诊断文件的说明（P1 应换为结构化日志）。
    ref.listen(noteListProvider(_showDeleted), (_, AsyncValue<List<NoteItem>> next) {
      final int? count = next.value?.length;
      if (count != null && count != _lastLoadedCount) {
        _lastLoadedCount = count;
        unawaited(
          writeUiDiagnostics(<String>[
            'page=notes',
            'includeDeleted=$_showDeleted',
            'noteCount=$count',
            'noteTitles=${next.value!.map((NoteItem n) => n.title).join(' | ')}',
            'databasePath=${engine.value?.databasePath}',
          ]),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(engine.value?.displayName ?? '拾光笔记'),
        actions: <Widget>[
          IconButton(
            tooltip: _showDeleted ? '隐藏回收站' : '显示回收站',
            onPressed: () => setState(() => _showDeleted = !_showDeleted),
            icon: Icon(
              _showDeleted ? Icons.delete_outline : Icons.delete_outlined,
              color: _showDeleted ? Theme.of(context).colorScheme.primary : null,
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
        AsyncData() => _NotesList(includeDeleted: _showDeleted),
        _ => const Center(child: CircularProgressIndicator()),
      },
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createNote(context),
        icon: const Icon(Icons.add),
        label: const Text('新建笔记'),
      ),
    );
  }

  /// 新建笔记并直接进入编辑。
  Future<void> _createNote(BuildContext context) async {
    // 先取好 Navigator 与 messenger：await 之后不能再依赖 BuildContext
    // （analysis 的 use_build_context_synchronously 就是在拦这个）。
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NoteActions actions = ref.read(noteActionsProvider);
    try {
      final String id = await actions.create();
      await navigator.push(
        MaterialPageRoute<void>(builder: (_) => NoteEditorPage(noteId: id)),
      );
    } on NoteFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.hint)));
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

/// 列表主体。
class _NotesList extends ConsumerWidget {
  const _NotesList({required this.includeDeleted});

  final bool includeDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<NoteItem>> notes = ref.watch(
      noteListProvider(includeDeleted),
    );

    return switch (notes) {
      AsyncLoading() => const Center(child: CircularProgressIndicator()),
      AsyncError(:final Object error) => _FailureView(message: '$error'),
      AsyncData(:final List<NoteItem> value) when value.isEmpty =>
        _EmptyView(includeDeleted: includeDeleted),
      AsyncData(:final List<NoteItem> value) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(noteListProvider(includeDeleted)),
        child: ListView.separated(
          itemCount: value.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (BuildContext context, int index) {
            final NoteItem note = value[index];
            return ListTile(
              leading: Icon(
                note.deleted ? Icons.delete_outline : Icons.description_outlined,
                color: note.deleted
                    ? Theme.of(context).colorScheme.outline
                    : null,
              ),
              title: Text(
                note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                note.summary.isEmpty ? '（空）' : note.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                'v${note.version}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoteEditorPage(noteId: note.id),
                ),
              ),
              onLongPress: () => _confirmDelete(context, ref, note),
            );
          },
        ),
      ),
    };
  }

  /// 长按：删除或恢复。
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    NoteItem note,
  ) async {
    final NoteActions actions = ref.read(noteActionsProvider);
    final bool restore = note.deleted;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(restore ? '恢复这篇笔记？' : '移入回收站？'),
        content: Text(
          restore
              ? '《${note.title}》将回到笔记列表。'
              : '《${note.title}》将被移入回收站，可以随时恢复。\n\n数据不会被立即删除（软删除）。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(restore ? '恢复' : '移入回收站'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }
    try {
      if (restore) {
        await actions.restore(note.id);
      } else {
        await actions.delete(note.id);
      }
    } on NoteFailure catch (failure) {
      if (context.mounted) {
        _showError(context, failure.hint);
      }
    }
  }
}

/// 空列表提示。
class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.includeDeleted});

  final bool includeDeleted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            includeDeleted ? Icons.delete_outline : Icons.note_add_outlined,
            size: 56,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            includeDeleted ? '回收站是空的' : '还没有笔记',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            includeDeleted ? '删除的笔记会出现在这里' : '点击右下角「新建笔记」开始记录',
            style: theme.textTheme.bodySmall,
          ),
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

/// 显示一句可读的错误提示（不用 SnackBar 之外的花样，保持简单）。
void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
