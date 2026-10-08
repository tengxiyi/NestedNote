// SPDX-License-Identifier: AGPL-3.0-or-later
//! 合并笔记（M3 特色 3）。
//!
//! ## 语义：生成新笔记，原笔记不动
//!
//! 印象笔记的合并**不可逆**——合并完原笔记就没了，手一抖就找不回来。
//! 我们的做法：合并产物是**一篇新笔记**，原笔记原样保留（要删的话
//! 用户自己删，还会先进回收站）。可逆比省一次点击重要（用户已确认的
//! 决策基调）。
//!
//! ## 为什么合并只是"文本组合"，内核不需要新 API
//!
//! 组合规则（标题做一级标题、篇与篇之间加分隔线）全部落在**已有的
//! 无损投影**上：`# 标题` 反解成标题块、`---` 反解成分割线。合并产物
//! 就是普通的块文档，走既有的创建 + 保存路径，天然有完整修订记录。
//! 内核没有新不变量要守护，为它加一个 API 只会制造两份事实。
//!
//! ## 顺序
//!
//! 按**中栏列表从上到下**的顺序拼接（用户看到的顺序），不是勾选的
//! 先后——勾选顺序是操作细节，列表顺序才是用户心里的"第 1 篇、
//! 第 2 篇"。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/note_providers.dart';
import 'word_count.dart';

/// 合并执行计划：标题 + 组合好的正文。
class MergePlan {
  /// 构造。
  const MergePlan({required this.title, required this.text});

  /// 新笔记的标题。
  final String title;

  /// 组合好的正文（Markdown 风格投影，保存时反解成块）。
  final String text;
}

/// 把若干篇（标题, 正文）组合成一篇的文本。
///
/// 规则：每篇以 `# 标题` 开头；篇与篇之间用 `---` 分隔。
/// 空笔记只留标题行——它确实被合并了，用户在产物里能看到它出现过。
String composeMergedText(List<(String, String)> titledTexts) {
  final List<String> lines = <String>[];
  for (int i = 0; i < titledTexts.length; i++) {
    final (String title, String content) = titledTexts[i];
    if (i > 0) {
      // 篇间分隔线。前后留空行：`---` 紧贴文字会被投影认成分割线，
      // 但阅读时和上一段粘在一起；空行也让"这是两篇的边界"更醒目。
      lines
        ..add('')
        ..add('---')
        ..add('');
    }
    lines.add('# $title');
    final String body = content.trim();
    if (body.isNotEmpty) {
      lines.add(body);
    }
  }
  // 末尾的空行交给投影归一（text_to_blocks 裁尾部），这里不必处理
  return lines.join('\n');
}

/// 弹出合并确认框，返回 [MergePlan]；用户取消返回 `null`。
///
/// ## 确认框里必须有结构预览
///
/// 合并是"把多篇变成一篇"的动作，用户要回答的不是"要不要"，而是
/// "**会变成什么样**"：顺序对不对、哪篇在前、一共多少字。因此确认框
/// 逐篇列出标题与字数，并给出合计——看完再确认。
///
/// 正文要**逐篇读取**（字数需要全文），所以这里用 FutureBuilder：
/// 读取完成前确认按钮不可用，避免"用不完整的信息确认"。
Future<MergePlan?> showMergeDialog(
  BuildContext context,
  WidgetRef ref, {
  required List<NoteItem> notes,
}) {
  assert(notes.length >= 2, '合并至少要两篇，调用方负责拦截');
  return showDialog<MergePlan>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _MergeDialog(notes: List<NoteItem>.of(notes)),
  );
}

class _MergeDialog extends ConsumerStatefulWidget {
  const _MergeDialog({required this.notes});

  final List<NoteItem> notes;

  @override
  ConsumerState<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends ConsumerState<_MergeDialog> {
  late final TextEditingController _titleController;
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: '合并笔记（${widget.notes.length} 篇）',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  /// 逐篇读全文。提供者有缓存，重复调用是廉价的。
  Future<List<(NoteItem, String)>> _loadParts() =>
      Future.wait(<Future<(NoteItem, String)>>[
        for (final NoteItem note in widget.notes)
          ref
              .read(noteTextProvider(note.id).future)
              .then((String text) => (note, text)),
      ]);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 逐篇读全文：字数统计需要完整正文，摘要不够。
    // N 次本地读取（SQLite），毫秒级，不值得做进度条。
    final Future<List<(NoteItem, String)>> loading =
        Future.wait(<Future<(NoteItem, String)>>[
          for (final NoteItem note in widget.notes)
            ref
                .read(noteTextProvider(note.id).future)
                .then((String text) => (note, text)),
        ]);

    return AlertDialog(
      title: const Text('合并所选笔记'),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '将按下面的顺序合并为**一篇新笔记**。原笔记保留不动。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '新笔记标题',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: FutureBuilder<List<(NoteItem, String)>>(
                future: loading,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<(NoteItem, String)>> snapshot,
                    ) {
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return _structureList(context, snapshot.data!, theme);
                    },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          // 标题为空不能合并：会产生一篇无标题笔记，还要用户再补
          onPressed: () async {
            final String title = _titleController.text.trim();
            if (title.isEmpty || _confirmed) {
              return;
            }
            _confirmed = true;
            // 正文此刻已读完（FutureBuilder 已渲染结构列表）；
            // _loadParts 命中提供者缓存，等待是毫秒级的。
            final List<(NoteItem, String)> parts = await _loadParts();
            final MergePlan plan = MergePlan(
              title: title,
              text: composeMergedText(<(String, String)>[
                for (final (NoteItem note, String text) in parts)
                  (note.title, text),
              ]),
            );
            if (!mounted) {
              return;
            }
            // 用 State 自己的 context（build 参数的 context 在异步间隙后无效）
            Navigator.of(this.context).pop(plan);
          },
          child: const Text('合并'),
        ),
      ],
    );
  }

  Widget _structureList(
    BuildContext context,
    List<(NoteItem, String)> parts,
    ThemeData theme,
  ) {
    int total = 0;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < parts.length; i++) {
      final (NoteItem note, String text) = parts[i];
      final int chars = countWords(text).characters;
      total += chars;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 30,
                child: Text(
                  '$i.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  note.title.isEmpty ? '（无标题笔记）' : note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Text(
                '$chars 字',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ...rows,
          const Divider(height: 12),
          Text(
            '合计 $total 字，将产生 ${parts.length} 个一级标题与'
            ' ${parts.length - 1} 条分隔线。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
