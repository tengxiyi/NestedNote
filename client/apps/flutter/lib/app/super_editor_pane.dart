// SPDX-License-Identifier: AGPL-3.0-or-later
//! 右栏编辑面（R2）：super_editor 所见即所得 + 工具栏（ADR 0002 §8）。
//!
//! ## 数据通路
//!
//! 加载：内核文本投影（Markdown）→ `deserializeMarkdownToDocument` → 编辑。
//! 保存：`serializeDocumentToMarkdown` → 既有 `save_note` 路径
//! （修订/导出/活动日志全沿用）。桥接零自研映射。
//!
//! ## 保留的迁移兜底
//!
//! 「预览」按钮仍切换到 R1 的 DocumentView 只读渲染——super_editor
//! 面与 R1 视图读同一份数据，直到 R2 完全稳定再移除（ADR 迁移策略）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_editor/super_editor.dart';

import '../core/note_providers.dart';
import '../core/blocks.dart' as blocks;
import 'document_view.dart';
import 'icons.dart';
import 'tag_editor.dart';
import 'revision_history.dart';
import 'attachments_dialog.dart';
import 'typography.dart';
import 'word_count.dart';

const Duration kEditorAutoSaveDelay = Duration(seconds: 1);

/// 右栏编辑面：标题 + 工具栏 + 状态行 + 编辑器/预览。
class NoteEditorPane extends ConsumerStatefulWidget {
  /// 构造。
  const NoteEditorPane({required this.noteId, super.key});

  /// 要编辑的笔记标识。
  final String noteId;

  @override
  ConsumerState<NoteEditorPane> createState() => _NoteEditorPaneState();
}

class _NoteEditorPaneState extends ConsumerState<NoteEditorPane> {
  final TextEditingController _titleController = TextEditingController();
  Editor? _editor;
  CommonEditorOperations? _ops;
  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  bool _autoSaveFailed = false;
  String _savedMarkdown = '';
  String _savedTitle = '';
  Timer? _autoSaveTimer;
  EditorSaveChannel? _saveChannel;
  EditorReloadChannel? _reloadChannel;
  final GlobalKey _docLayoutKey = GlobalKey();

  late final Future<void> Function() _savingCallback;
  late final Future<void> Function() _reloadCallback;
  bool _previewing = false;
  Future<List<blocks.UiBlock>>? _previewFuture;

  bool get _dirty =>
      !_loading &&
      _editor != null &&
      (serializeDocumentToMarkdown(_editor!.document) != _savedMarkdown ||
          _titleController.text != _savedTitle);

  @override
  void initState() {
    super.initState();
    _saveChannel = ref.read(editorSaveChannelProvider.notifier);
    _reloadChannel = ref.read(editorReloadChannelProvider.notifier);
    _savingCallback = _saveNow;
    _reloadCallback = _load;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _saveChannel?.register(_savingCallback);
      _reloadChannel?.register(_reloadCallback);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _saveChannel?.unregister(_savingCallback);
    _reloadChannel?.unregister(_reloadCallback);
    if (_dirty) {
      final String markdown = serializeDocumentToMarkdown(_editor!.document);
      unawaited(
        ref
            .read(noteActionsProvider)
            .save(widget.noteId, title: _titleController.text, text: markdown),
      );
    }
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final NoteSnapshot snapshot = await ref.read(
        noteSnapshotProvider(widget.noteId).future,
      );
      final MutableDocument document = deserializeMarkdownToDocument(
        snapshot.text,
      );
      final MutableDocumentComposer composer = MutableDocumentComposer();
      if (!mounted) {
        return;
      }
      setState(() {
        _titleController.text = snapshot.title;
        _savedTitle = snapshot.title;
        _savedMarkdown = snapshot.text;
        _editor = Editor(
          editables: <String, Editable>{
            Editor.documentKey: document,
            Editor.composerKey: composer,
          },
          isHistoryEnabled: true,
          listeners: <EditListener>[FunctionalEditListener((_) => _onEdited())],
        );
        _ops = CommonEditorOperations(
          editor: _editor!,
          document: document,
          composer: composer,
          documentLayoutResolver: () =>
              _docLayoutKey.currentState as DocumentLayout,
        );
        _loading = false;
      });
    } on NoteFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = failure.hint;
      });
    }
  }

  void _onEdited() {
    setState(() {});
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(kEditorAutoSaveDelay, () {
      unawaited(_save());
    });
  }

  /// 立即保存（菜单/工具栏共用）。
  Future<void> _saveNow() async {
    if (_loading || _loadError != null) {
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    final Editor? editor = _editor;
    if (editor == null || _saving) {
      return;
    }
    final String markdown = serializeDocumentToMarkdown(editor.document);
    final String title = _titleController.text;
    if (markdown == _savedMarkdown && title == _savedTitle) {
      return;
    }
    setState(() {
      _saving = true;
      _autoSaveFailed = false;
    });
    try {
      await ref
          .read(noteActionsProvider)
          .save(widget.noteId, title: title, text: markdown);
      if (!mounted) {
        return;
      }
      setState(() {
        _savedMarkdown = markdown;
        _savedTitle = title;
        _saving = false;
      });
    } on NoteFailure {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _autoSaveFailed = true;
      });
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
    final Editor? editor = _editor;
    if (editor == null) {
      return const Center(child: CircularProgressIndicator());
    }
    const bool compact = false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 工具栏（R2：所见即所得的格式入口，取代旧文本标记菜单）
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              _toolButton(
                label: 'H1',
                onTap: () => _toggleBlockType(header1Attribution),
              ),
              _toolButton(
                label: 'H2',
                onTap: () => _toggleBlockType(header2Attribution),
              ),
              _toolButton(
                label: 'H3',
                onTap: () => _toggleBlockType(header3Attribution),
              ),
              _toolDivider(),
              _toolIcon(
                context,
                tooltip: '无序列表',
                icon: Icons.format_list_bulleted,
                onTap: () => _toggleList(ordered: false),
              ),
              _toolIcon(
                context,
                tooltip: '有序列表',
                icon: Icons.format_list_numbered,
                onTap: () => _toggleList(ordered: true),
              ),
              _toolIcon(
                context,
                tooltip: '待办',
                icon: Icons.check_box_outlined,
                onTap: _toggleTask,
              ),
              _toolIcon(
                context,
                tooltip: '引用',
                icon: Icons.format_quote,
                onTap: _toggleQuote,
              ),
              _toolIcon(
                context,
                tooltip: '分隔线',
                icon: Icons.horizontal_rule,
                onTap: _insertDivider,
              ),
              _toolDivider(),
              _toolIcon(
                context,
                tooltip: '加粗',
                icon: Icons.format_bold,
                onTap: () => _toggleInline(<Attribution>{boldAttribution}),
              ),
              _toolIcon(
                context,
                tooltip: '斜体',
                icon: Icons.format_italic,
                onTap: () => _toggleInline(<Attribution>{italicsAttribution}),
              ),
              _toolIcon(
                context,
                tooltip: '删除线',
                icon: Icons.format_strikethrough,
                onTap: () =>
                    _toggleInline(<Attribution>{strikethroughAttribution}),
              ),
              _toolIcon(
                context,
                tooltip: '行内代码',
                icon: Icons.code,
                onTap: () => _toggleInline(<Attribution>{codeAttribution}),
              ),
              const SizedBox(width: 20),
              IconButton(
                tooltip: '标签',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (_dirty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请先保存，再编辑标签。')),
                    );
                    return;
                  }
                  unawaited(
                    showTagEditor(
                      context,
                      noteId: widget.noteId,
                      noteTitle: _titleController.text,
                    ),
                  );
                },
                icon: const Icon(kEditTagsIcon, size: 20),
              ),
              IconButton(
                tooltip: '修订历史',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (_dirty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请先保存，再查看修订历史。')),
                    );
                    return;
                  }
                  unawaited(
                    showRevisionHistory(
                      context,
                      noteId: widget.noteId,
                      noteTitle: _titleController.text,
                    ),
                  );
                },
                icon: const Icon(kHistoryIcon, size: 20),
              ),
              IconButton(
                tooltip: '附加文件',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                    context,
                  );
                  if (_dirty) {
                    unawaited(_saveNow());
                  }
                  unawaited(
                    pickAndAttachFile(
                      noteId: widget.noteId,
                      reloadNote: _load,
                    ).then((String? failure) {
                      if (failure != null) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(failure)),
                        );
                      }
                    }),
                  );
                },
                icon: const Icon(Icons.attach_file, size: 20),
              ),
              IconButton(
                tooltip: '附件列表',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(
                  showAttachmentsDialog(context, ref, noteId: widget.noteId),
                ),
                icon: const Icon(Icons.folder_zip_outlined, size: 20),
              ),
              IconButton(
                tooltip: _previewing ? '返回编辑' : '预览（只读渲染）',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (!_previewing && _dirty) {
                    unawaited(_saveNow());
                  }
                  setState(() {
                    _previewing = !_previewing;
                    _previewFuture = _previewing
                        ? blocks.fetchNoteBlocks(widget.noteId)
                        : null;
                  });
                },
                icon: Icon(
                  _previewing ? Icons.edit_outlined : Icons.visibility_outlined,
                  size: 20,
                ),
              ),
              IconButton(
                tooltip: '立即保存',
                visualDensity: VisualDensity.compact,
                onPressed: _dirty ? () => unawaited(_saveNow()) : null,
                icon: const Icon(Icons.save_outlined, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: TextField(
            controller: _titleController,
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
            onChanged: (_) => _onEdited(),
          ),
        ),
        if (!compact) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Row(
              children: <Widget>[
                Text(
                  countWords(_documentText()).summary,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 20),
                Icon(
                  _saving
                      ? Icons.sync
                      : _autoSaveFailed
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 14,
                  color: _autoSaveFailed
                      ? theme.colorScheme.error
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  _saving
                      ? '正在保存…'
                      : _autoSaveFailed
                      ? '自动保存失败'
                      : _dirty
                      ? '有未保存的改动'
                      : '已保存',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _autoSaveFailed ? theme.colorScheme.error : null,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 4),
        Expanded(
          child: _previewing
              ? _previewArea(theme)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: SuperEditor(
                    editor: editor,
                    documentLayoutKey: _docLayoutKey,
                  ),
                ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- 工具栏动作

  void _toggleInline(Set<Attribution> attributions) {
    _ops?.toggleAttributionsOnSelection(attributions);
  }

  void _toggleBlockType(Attribution target) {
    final String? nodeId = _selectedNodeId();
    if (nodeId == null) {
      return;
    }
    final DocumentNode? node = _editor!.document.getNodeById(nodeId);
    final Object? current = node?.metadata['blockType'];
    _editor!.execute(<EditRequest>[
      ChangeParagraphBlockTypeRequest(
        nodeId: nodeId,
        blockType: current == target ? paragraphAttribution : target,
      ),
    ]);
  }

  void _toggleList({required bool ordered}) {
    final String? nodeId = _selectedNodeId();
    if (nodeId == null) {
      return;
    }
    final DocumentNode? node = _editor!.document.getNodeById(nodeId);
    final Object? blockType = node?.metadata['blockType'];
    final bool isList =
        blockType == const NamedAttribution('unordered') ||
        blockType == const NamedAttribution('ordered');
    if (isList) {
      _editor!.execute(<EditRequest>[
        ConvertListItemToParagraphRequest(nodeId: nodeId),
      ]);
      return;
    }
    _ops?.convertToListItem(
      ordered ? ListItemType.ordered : ListItemType.unordered,
      _selectedText(),
    );
  }

  void _toggleTask() {
    final String? nodeId = _selectedNodeId();
    if (nodeId == null) {
      return;
    }
    final DocumentNode? node = _editor!.document.getNodeById(nodeId);
    if (node is TaskNode) {
      _editor!.execute(<EditRequest>[
        ConvertTaskToParagraphRequest(nodeId: nodeId),
      ]);
      return;
    }
    _editor!.execute(<EditRequest>[
      ConvertParagraphToTaskRequest(nodeId: nodeId, isComplete: false),
    ]);
  }

  void _toggleQuote() {
    final String? nodeId = _selectedNodeId();
    if (nodeId == null) {
      return;
    }
    final DocumentNode? node = _editor!.document.getNodeById(nodeId);
    final Object? current = node?.metadata['blockType'];
    if (current == blockquoteAttribution) {
      _editor!.execute(<EditRequest>[
        ChangeParagraphBlockTypeRequest(
          nodeId: nodeId,
          blockType: paragraphAttribution,
        ),
      ]);
      return;
    }
    _ops?.convertToBlockquote(_selectedText());
  }

  void _insertDivider() {
    _ops?.insertHorizontalRule();
  }

  String? _selectedNodeId() {
    final DocumentSelection? selection = _editor?.composer.selection;
    return selection?.extent.nodeId;
  }

  AttributedText _selectedText() {
    final String? nodeId = _selectedNodeId();
    final DocumentNode? node = nodeId == null
        ? null
        : _editor!.document.getNodeById(nodeId);
    if (node is TextNode) {
      return node.text;
    }
    return AttributedText('');
  }

  String _documentText() {
    final Editor? editor = _editor;
    if (editor == null) {
      return '';
    }
    final StringBuffer buffer = StringBuffer();
    for (final DocumentNode node in editor.document) {
      if (node is TextNode) {
        buffer.writeln(node.text.toPlainText());
      }
    }
    return buffer.toString();
  }

  Widget _toolButton({required String label, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
      ),
    );
  }

  Widget _toolIcon(
    BuildContext context, {
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: Icon(icon, size: 18),
    );
  }

  Widget _toolDivider() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 4),
    child: SizedBox(height: 18, child: VerticalDivider(width: 1)),
  );

  // ------------------------------------------------------------- 预览（R1 兜底）

  Widget _previewArea(ThemeData theme) {
    _previewFuture ??= blocks.fetchNoteBlocks(widget.noteId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: FutureBuilder<List<blocks.UiBlock>>(
        future: _previewFuture,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<blocks.UiBlock>> snapshot,
            ) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    '预览读取失败：${snapshot.error}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                );
              }
              return DocumentView(
                blocks: snapshot.data ?? const <blocks.UiBlock>[],
                noteId: widget.noteId,
              );
            },
      ),
    );
  }
}
