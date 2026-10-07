// SPDX-License-Identifier: AGPL-3.0-or-later
//! 笔记编辑面板 —— 三栏布局的**右栏**。
//!
//! ## 两种形态
//!
//! | 组件 | 形态 | 用途 |
//! |---|---|---|
//! | [`NoteEditorPane`] | 栏内面板（无 Scaffold / AppBar） | 主界面的右栏 |
//! | [`NoteEditorPage`] | 整页（带 AppBar 与返回） | 需要独立路由时（例如从搜索结果直接打开） |
//!
//! 两者共用同一套编辑状态机（[NoteEditorPane]），页面形态只是给它套了个壳。
//! 这样"自动保存""未保存提示"这些行为不会出现两份实现。
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
//! 2. **同一时刻只有一个保存请求在飞**（`_saving` 标志）——
//!    自动保存是"最后一次输入为准"，不能并发发出多个请求。
//!
//! 手动保存按钮仍在：它给用户一个明确的"现在立刻存"的出口。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/note_providers.dart';

/// 停止输入多久之后自动保存。
///
/// 1.2 秒是取舍：太短会在连续输入时频繁触发（虽然内容未变时会跳过，
/// 但每次仍要走一次 FFI），太长则用户切走时更容易丢失内容。
const Duration kAutoSaveDelay = Duration(milliseconds: 1200);

/// 笔记编辑面板（三栏布局的右栏）。
class NoteEditorPane extends ConsumerStatefulWidget {
  /// 构造。
  const NoteEditorPane({required this.noteId, super.key});

  /// 要编辑的笔记标识。
  final String noteId;

  @override
  ConsumerState<NoteEditorPane> createState() => _NoteEditorPaneState();
}

class _NoteEditorPaneState extends ConsumerState<NoteEditorPane> {
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
    // 离开前取消计时器（不等保存结果：dispose 不能异步）。
    // 真正的保障是离开前的确认流程，这里只是兜底。
    _autoSaveTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final String text = await ref.read(
        noteTextProvider(widget.noteId).future,
      );
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
    _autoSaveTimer = Timer(
      kAutoSaveDelay,
      () => unawaited(_save(automatic: true)),
    );
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_loadError!, textAlign: TextAlign.center),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 面板内的工具条：保存按钮 + 保存状态。
        // 三栏布局下没有整页 AppBar，因此这些控件必须有自己的位置。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: <Widget>[
              if (_saving)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.cloud_done_outlined,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _saving
                      ? '正在保存…'
                      : (_autoSaveFailed
                            ? '自动保存失败'
                            : (_dirty ? '有未保存的改动' : '已保存')),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _autoSaveFailed ? theme.colorScheme.error : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: '立即保存',
                visualDensity: VisualDensity.compact,
                onPressed: _dirty ? _save : null,
                icon: const Icon(Icons.save_outlined, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
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
                hintText:
                    '开始写点什么…\n\n'
                    '（P1 编辑器为纯文本：每行会保存为一个段落块。停止输入后会自动保存。）',
              ),
              onChanged: _onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// 笔记编辑页（整页形态）。
///
/// 用于需要独立路由的场景（例如将来从搜索结果直接打开一篇笔记）。
/// 主界面的右栏请用 [NoteEditorPane]。
class NoteEditorPage extends StatelessWidget {
  /// 构造。
  const NoteEditorPage({required this.noteId, super.key});

  /// 要编辑的笔记标识。
  final String noteId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑笔记')),
      body: NoteEditorPane(noteId: noteId),
    );
  }
}
