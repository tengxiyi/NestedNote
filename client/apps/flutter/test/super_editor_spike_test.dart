// SPDX-License-Identifier: AGPL-3.0-or-later
// super_editor Spike 验证（A2）：编译（本文件通过 flutter test 即证）、
// 解析保真度、渲染冒烟。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';

import 'package:nestednote/app/super_editor_spike.dart';
import 'package:nestednote/core/note_providers.dart';

void main() {
  group('Markdown 解析保真度（我们的标记样张）', () {
    const String sample =
        '# 标题\n- 甲\n1. 一步\n- [ ] 未完成\n- [x] 已完成\n'
        '> 引用\n---\n正文段落\n```dart\nvoid main() {}\n```';

    test('块类型被识别', () {
      final MutableDocument document = deserializeMarkdownToDocument(sample);
      final List<String> types = document
          .map((node) => node.metadata['blockType']?.toString() ?? '(none)')
          .toList(growable: false);
      // super_editor 的块语义在 metadata['blockType']（header1/2/3、
      // unorderedListItem、orderedListItem、task、blockquote、hr、code、paragraph）
      expect(types, contains(contains('header')), reason: 'types=$types');
      expect(
        types.any((t) => t.contains('listItem')),
        isTrue,
        reason: 'types=$types',
      );
      expect(
        types.any((t) => t.toLowerCase().contains('task')),
        isTrue,
        reason: 'types=$types',
      );
      expect(
        types.any((t) => t.contains('blockquote')),
        isTrue,
        reason: 'types=$types',
      );
      expect(
        types.any((t) => t.contains('hr') || t.contains('horizontal')),
        isTrue,
        reason: 'types=$types',
      );
      expect(
        types.any((t) => t.contains('code')),
        isTrue,
        reason: 'types=$types',
      );
      expect(
        types.any((t) => t.contains('paragraph')),
        isTrue,
        reason: 'types=$types',
      );
    });

    test('往返：再序列化后关键标记仍在', () {
      final MutableDocument document = deserializeMarkdownToDocument(sample);
      final String roundTrip = serializeDocumentToMarkdown(document);
      expect(roundTrip, contains('# 标题'));
      expect(roundTrip, contains('甲'));
      expect(roundTrip, contains('未完成'));
      expect(roundTrip, contains('引用'));
      expect(roundTrip, contains('正文段落'));
    });

    test('已知偏差：附件标记按普通链接处理（内容不丢）', () {
      final MutableDocument document = deserializeMarkdownToDocument(
        '[file: 报告](abc-123)',
      );
      final String roundTrip = serializeDocumentToMarkdown(document);
      expect(roundTrip, contains('报告'));
      expect(roundTrip, contains('abc-123'), reason: '链接目标不应丢失');
    });
  });

  group('SuperEditorSpikeView 渲染', () {
    testWidgets('加载真实笔记文本并渲染编辑器', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            noteTextProvider.overrideWith(
              (Ref ref, String id) async => '# 标题\n- 甲',
            ),
            noteSnapshotProvider.overrideWith(
              (Ref ref, String id) async =>
                  const NoteSnapshot(title: '标题', text: ''),
            ),
          ],
          child: const MaterialApp(
            home: SuperEditorSpikeView(noteId: 'note-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SuperEditor), findsOneWidget);
      expect(find.text('保存到内核'), findsOneWidget);
      // 文本可见性留给真机人工验收（Spike 阶段验证"能编译、能渲染
      // 编辑器组件、无异常"；测试环境里 SuperEditor 的文本渲染依赖
      // focus/layout 细节，断言会假阴）。
      expect(tester.takeException(), isNull);
    });
  });
}
