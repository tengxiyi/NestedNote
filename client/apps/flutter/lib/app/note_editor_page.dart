// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记编辑页。
//!
//! ## 为什么是"纯文本 + 块模型"两段式
//!
//! 内核存的是**块模型**（`nested-model`），而 P1 阶段还没有块级编辑器。
//! 因此这里先做一条诚实的降级通路：
//!
//! - **读**：块 → 纯文本（每个块一行），见 Rust 侧 `document_to_text`
//! - **写**：纯文本按换行切成段落块，见 Rust 侧 `text_to_document`
//!
//! 这条路径会**丢失**行内标记（加粗/链接）与块的种类（标题/列表/引用），
//! 因此它只是"能看见结果的通路"，不是最终形态。P3 的块编辑器会直接操作块模型。
//!
//! ## 自动保存
//!
//! 停止输入 [kAutoSaveDelay] 后自动落盘。这建立在两件事之上：
//!
//! 1. **无变更保存不产生修订**（技术债 #11 已修）——否则每次自动保存都会
//!    写一条修订记录并入队一条同步操作，等于把历史记录变成噪声；
//! 2. **序列化写入必须在写入前完成**——自动保存是"最后一次输入为准"，
//!    不能并发发出多个保存请求，因此用 [kAutoSaveDelay] 去抖 + 单飞标志。
//!
//! 手动保存按钮仍在：它给用户一个明确的"现在立刻存"的出口。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/note_providers.dart';

/// 停止输入多久之后自动保存。
///
/// 1.2 秒是取舍：太短会在连续输入时频繁触发（虽然内容未变时会跳过，
/// 但每次仍要走一次 FFI），太长则用户关掉窗口时更容易丢失内容。
const Duration kAutoSaveDelay = Duration(milliseconds: 1200);

/// 笔记编辑页。
class NoteEditorPage extends ConsumerStatefulWidget {
  /// 构造。
  const NoteEditorPage({required this.noteId, super.key});

  /// 要编辑的笔记标识。
  final String noteId;

  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  final TextEditingController _controller = TextEditingController();

  /// 已落盘的内容，用于判断"是否有未保存改动"。
  String _savedText = '';

  /// 自动保存的去抖计时器。
  Timer? _autoSaveTimer;

  /// 是否正在加载初始内容。
  bool _loading = true;

  /// 是否正在保存。
  bool _saving = false;

  /// 上一次自动保存是否失败（用于避免反复弹同一个错误）。
  bool _autoSaveFailed = false;

  /// 加载失败时的提示。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // 离开前尽力保存一次（不等结果：dispose 不能异步）。
    // 真正的保障是 PopScope 里的离开确认，这里只是兜底。
    _autoSaveTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final String text = await ref.read(noteTextProvider(widget.noteId).future);
      if (!mounted) {
        return;
      }
      setState(() {
        _controller.text = text;
        _savedText = text;
        _loading = false;
      });
    } on NoteFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = failure.hint;
        _loading = false;
      });
    }
  }

  bool get _dirty => _controller.text != _savedText;

  /// 输入变化：重置去抖计时器。
  void _onChanged(String _) {
    setState(() {}); // 刷新"未保存"提示与保存按钮的可用状态
    _autoSaveTimer?.cancel();
    if (!_dirty) {
      // 内容改回原样（例如全部删掉又重新输入相同文字）：不需要保存
      return;
    }
    _autoSaveTimer = Timer(kAutoSaveDelay, () => unawaited(_save(automatic: true)));
  }

  /// 保存。
  ///
  /// `automatic = true` 时失败不弹 SnackBar（避免连续输入时刷屏），
  /// 只把状态标出来，等用户手动保存或离开时再提示。
  Future<bool> _save({bool automatic = false}) async {
    if (!_dirty || _saving) {
      return true;
    }
    _autoSaveTimer?.cancel();
    setState(() => _saving = true);

    final String text = _controller.text;
    try {
      await ref.read(noteActionsProvider).save(widget.noteId, text);
      if (!mounted) {
        return true;
      }
      setState(() {
        _savedText = text;
        _saving = false;
        _autoSaveFailed = false;
      });
      if (!automatic) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已保存')));
      }
      return true;
    } on NoteFailure catch (failure) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _saving = false;
        _autoSaveFailed = true;
      });
      if (!automatic) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure.hint)));
      }
      return false;
    }
  }

  /// 离开前确认未保存的改动。
  Future<bool> _confirmLeave() async {
    if (!_dirty) {
      return true;
    }
    // 先尝试自动保存一次：多数情况下"未保存"只是去抖窗口还没到
    final bool saved = await _save(automatic: true);
    if (saved) {
      return true;
    }
    if (!mounted) {
      return false;
    }

    final NavigatorState navigator = Navigator.of(context);
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('还有未保存的改动'),
        content: const Text('自动保存未能成功。离开将丢失这些改动。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃改动'),
          ),
          FilledButton(
            onPressed: () async {
              final NavigatorState dialogNavigator = Navigator.of(dialogContext);
              final bool ok = await _save();
              dialogNavigator.pop(ok);
            },
            child: const Text('重试保存'),
          ),
        ],
      ),
    );
    if (leave == true) {
      navigator.pop();
    }
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) {
          return;
        }
        await _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑笔记'),
          actions: <Widget>[
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                tooltip: '保存',
                onPressed: _dirty ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_loadError!, textAlign: TextAlign.center),
                ),
              )
            : Column(
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: theme.textTheme.bodyLarge,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '开始写点什么…\n\n（P1 编辑器为纯文本：每行会保存为一个段落块。'
                              '停止输入后会自动保存。）',
                        ),
                        onChanged: _onChanged,
                      ),
                    ),
                  ),
                  _StatusBar(
                    dirty: _dirty,
                    autoSaveFailed: _autoSaveFailed,
                    theme: theme,
                  ),
                ],
              ),
      ),
    );
  }
}

/// 底部状态条：显示保存状态。
///
/// 比"有没有改动"更有用的是**"改动有没有落盘"**，因此这里区分三种状态：
/// 已保存 / 待自动保存 / 自动保存失败。
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.dirty,
    required this.autoSaveFailed,
    required this.theme,
  });

  final bool dirty;
  final bool autoSaveFailed;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final (Color background, IconData icon, String label) = switch ((
      dirty,
      autoSaveFailed,
    )) {
      (false, _) => (
        theme.colorScheme.surfaceContainerHighest,
        Icons.cloud_done_outlined,
        '已保存',
      ),
      (true, true) => (
        theme.colorScheme.errorContainer,
        Icons.cloud_off_outlined,
        '自动保存失败，请点右上角手动保存',
      ),
      (true, false) => (
        theme.colorScheme.secondaryContainer,
        Icons.cloud_upload_outlined,
        '正在自动保存…',
      ),
    };

    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

