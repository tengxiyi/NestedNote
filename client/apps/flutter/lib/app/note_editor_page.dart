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
import 'icons.dart';
import 'typography.dart';
import 'revision_history.dart';
import 'tag_editor.dart';

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
  /// 从列表缓存里取这篇笔记的标题。
  ///
  /// 编辑器本身不需要标题（正文即内容），但标签与历史对话框要显示
  /// "这是哪篇笔记的"。取不到就退回通用标题，而不是显示空串。
  String _noteTitle(WidgetRef ref) =>
      ref
          .read(noteListMergedProvider(const NoteListQuery()))
          .value
          ?.where((NoteItem item) => item.id == widget.noteId)
          .map((NoteItem item) => item.title)
          .firstOrNull ??
      '笔记';

  final TextEditingController _controller = TextEditingController();

  /// 标题输入框。
  ///
  /// 标题与正文是**两个输入框、一次保存**（见 `notes_save` 的说明）：
  /// 分成两次调用会出现"标题存了、正文没存"的中间状态。
  final TextEditingController _titleController = TextEditingController();

  /// 已落盘的标题，用于判断标题是否被改过。
  String _savedTitle = '';

  /// 正文的焦点节点。
  ///
  /// 标题框 `autofocus`，但**只对新建（标题为空的）笔记**合适：
  /// 打开一篇已有笔记时，用户想接着写正文，焦点却停在标题上会更烦人。
  /// 因此加载完成后按"标题是否为空"决定把焦点交给谁。
  final FocusNode _bodyFocus = FocusNode();

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

  /// 用于在 [dispose] 里补一次保存。
  ///
  /// ## 为什么必须持有它（这是一个真实的数据丢失缺陷的修法）
  ///
  /// `dispose()` 是同步的，不能 `await`，而且之后不能再碰 `ref`。
  /// 但用户完全可能在"输入后不到 [kAutoSaveDelay]"就切走——
  /// 那时去抖计时器还没触发，`dispose` 又把它取消掉，**输入就没了**。
  ///
  /// 本项目确实丢过数据：症状是"输入文字后切出去再切回来，笔记是空的"。
  /// 还有一个更隐蔽的同源缺陷：`NoteActions.save` 早先不失效正文缓存，
  /// 于是切回来时读到旧文本、把新内容盖掉（已修）。
  ///
  /// 这里在 initState 里把动作对象存下来，dispose 时直接调用——
  /// `save()` 的**第一个 await 之前**就取好了文本，所以调用后即使本组件
  /// 已被销毁，写库仍会完成（不依赖 `mounted`）。
  NoteActions? _actionsForFlush;

  @override
  void initState() {
    super.initState();
    // 提前取好，供 dispose 补保存用（dispose 时不能再碰 ref）
    _actionsForFlush = ref.read(noteActionsProvider);
    unawaited(_load());
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    // **补一次保存**：用户可能在去抖窗口内就切走了。
    //
    // 这是"输入后切走就丢"的直接修法。注意：
    // - 只在确实有未保存改动时才写，避免无谓的写与修订记录；
    // - 不 `await`（dispose 不能异步），但 `save()` 在第一个 await 之前
    //   就已经取好了文本，因此写库会完成；
    // - `save()` 内部用 `atMs = now`，不依赖组件还活着。
    if (_dirty && !_loading && _loadError == null) {
      unawaited(
        _actionsForFlush?.save(
          widget.noteId,
          title: _titleController.text,
          text: _controller.text,
        ),
      );
    }
    _bodyFocus.dispose();
    _titleController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // 一次读回标题与正文：它们属于同一篇笔记，分两次读会出现
      // "标题是新的、正文是旧的"这种自相矛盾的中间画面。
      //
      // 不写显式类型：那是 FFI 层的东西，界面只认 NoteSnapshot
      // （门禁 A-LAYERING 禁止 lib/app 直接 import 生成绑定）。
      final NoteSnapshot snapshot = await ref.read(
        noteSnapshotProvider(widget.noteId).future,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _titleController.text = snapshot.title;
        _controller.text = snapshot.text;
        _savedTitle = snapshot.title;
        _savedText = snapshot.text;
        _loading = false;
      });
      // 标题为空（新建的笔记）→ 焦点留在标题上，符合"先起名再写"的顺序；
      // 已有标题 → 把焦点交给正文，因为用户多半是来接着写的。
      if (snapshot.title.isNotEmpty) {
        _bodyFocus.requestFocus();
      }
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

  /// 是否有未保存的改动（标题或正文）。
  bool get _dirty =>
      _controller.text != _savedText || _titleController.text != _savedTitle;

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
    final String title = _titleController.text;
    try {
      await ref
          .read(noteActionsProvider)
          .save(widget.noteId, title: title, text: text);
      if (!mounted) {
        return true;
      }
      setState(() {
        _savedText = text;
        _savedTitle = title;
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
                Icon(kSavedIcon, size: 16, color: theme.colorScheme.outline),
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
                tooltip: '标签',
                visualDensity: VisualDensity.compact,
                // 与"修订历史"同样的理由：先保存再改标签，
                // 避免用户以为标签没生效。
                onPressed: () {
                  if (_dirty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请先保存，再编辑标签。')),
                    );
                    return;
                  }
                  showTagEditor(
                    context,
                    noteId: widget.noteId,
                    noteTitle: _noteTitle(ref),
                  );
                },
                icon: const Icon(kEditTagsIcon, size: 20),
              ),
              IconButton(
                tooltip: '修订历史',
                visualDensity: VisualDensity.compact,
                // 有未保存改动时提示先保存：否则用户会在历史里找不到
                // 自己刚写的内容，以为丢了。
                onPressed: () {
                  if (_dirty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请先保存，再查看修订历史。')),
                    );
                    return;
                  }
                  showRevisionHistory(
                    context,
                    noteId: widget.noteId,
                    noteTitle: _noteTitle(ref),
                  );
                },
                icon: const Icon(kHistoryIcon, size: 20),
              ),
              IconButton(
                tooltip: '立即保存',
                visualDensity: VisualDensity.compact,
                onPressed: _dirty ? _save : null,
                icon: const Icon(kSaveIcon, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 标题区：位于正文上方，字号明显大于正文（参照印象笔记的布局）。
        //
        // 它是**独立输入框**而不是"正文第一行特殊对待"：
        // 后者会让"改标题"与"删掉第一行"变成同一个动作，
        // 用户想删一行文字却把标题弄没了。
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: TextField(
            controller: _titleController,
            autofocus: true,
            maxLines: 1,
            textInputAction: TextInputAction.next,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: kEmphasisWeight,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: '标题',
            ),
            onChanged: (_) => _onChanged(''),
            // 在标题里按回车跳到正文，符合"填完标题接着写"的习惯
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: TextField(
              controller: _controller,
              focusNode: _bodyFocus,
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
