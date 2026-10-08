// SPDX-License-Identifier: AGPL-3.0-or-later
// R1 富显示的测试：JSON 解析 + 渲染冒烟。
//
// ## 测试边界
//
// 解析是数据正确性的关键（渲染错 = 用户看到错的内容）；
// 渲染是组件树的组装（冒烟即可，样式细节不值得钉）。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/document_view.dart';
import 'package:nested/core/blocks.dart';

void main() {
  group('JSON → UiBlock 解析', () {
    test('标题/列表/段落按 tag 解析', () {
      final String json = jsonEncode(<String, Object?>{
        'blocks': <Object?>[
          <String, Object?>{'type': 'heading', 'level': 2, 'text': '二级标题'},
          <String, Object?>{
            'type': 'list',
            'ordered': true,
            'start': 3,
            'items': <Object?>[
              <String, Object?>{'text': '甲'},
              <String, Object?>{'text': '乙'},
            ],
          },
          <String, Object?>{'type': 'paragraph', 'text': '正文'},
        ],
      });
      final List<UiBlock> blocks = parseBlocksJson(json);
      expect(blocks.length, 3);
      expect(blocks[0], isA<HeadingBlock>());
      final HeadingBlock heading = blocks[0] as HeadingBlock;
      expect(heading.level, 2);
      expect(heading.text, '二级标题');
      final ListBlock list = blocks[1] as ListBlock;
      expect(list.ordered, isTrue);
      expect(list.start, 3);
      expect(list.items, <String>['甲', '乙']);
      expect(blocks[2], isA<ParagraphBlock>());
    });

    test('待办/引用/代码/分隔线/链接', () {
      final String json = jsonEncode(<String, Object?>{
        'blocks': <Object?>[
          <String, Object?>{'type': 'checklist', 'text': '写完', 'checked': true},
          <String, Object?>{'type': 'quote', 'text': '引用', 'cite': '出处'},
          <String, Object?>{
            'type': 'code',
            'language': 'rust',
            'code': 'fn main() {}',
          },
          <String, Object?>{'type': 'divider'},
          <String, Object?>{
            'type': 'link',
            'text': '文档',
            'href': 'https://example.com',
          },
        ],
      });
      final List<UiBlock> blocks = parseBlocksJson(json);
      expect((blocks[0] as ChecklistBlock).checked, isTrue);
      expect((blocks[1] as QuoteBlock).cite, '出处');
      expect((blocks[2] as CodeBlock).language, 'rust');
      expect(blocks[3], isA<DividerBlock>());
      expect((blocks[4] as LinkBlock).href, 'https://example.com');
    });

    test('附件 id 是 UUID 字符串（serde transparent）', () {
      const String id = '0190f2a1-1111-7000-8000-000000000001';
      final String json = jsonEncode(<String, Object?>{
        'blocks': <Object?>[
          <String, Object?>{
            'type': 'file',
            'attachment_id': id,
            'filename': '报告.pdf',
          },
        ],
      });
      final FileBlock block = parseBlocksJson(json).single as FileBlock;
      expect(block.attachmentId, id);
      expect(block.filename, '报告.pdf');
    });

    test('未知类型保留为 UnknownBlock（不静默丢弃）', () {
      final String json = jsonEncode(<String, Object?>{
        'blocks': <Object?>[
          <String, Object?>{'type': 'hologram', 'text': '未来的块'},
        ],
      });
      final UnknownBlock block = parseBlocksJson(json).single as UnknownBlock;
      expect(block.kind, 'hologram');
    });

    test('空文档 → 空列表；结构坏掉 → 空列表不崩溃', () {
      expect(parseBlocksJson('{"blocks": []}'), isEmpty);
      expect(parseBlocksJson('{"no_blocks": true}'), isEmpty);
      expect(parseBlocksJson('not json at all'), isEmpty);
    });
  });

  group('DocumentView 渲染冒烟', () {
    testWidgets('标题/待办/代码/附件卡都出现', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: const MaterialApp(
            home: Scaffold(
              body: DocumentView(
                noteId: 'note-1',
                blocks: <UiBlock>[
                  HeadingBlock(1, '会议记录'),
                  ChecklistBlock('补齐菜单栏', true),
                  CodeBlock('sql', 'SELECT 1;'),
                  FileBlock('0190f2a1-1111-7000-8000-000000000001', '报告.pdf'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('会议记录'), findsOneWidget);
      expect(find.text('补齐菜单栏'), findsOneWidget);
      expect(find.text('SELECT 1;'), findsOneWidget);
      expect(find.text('报告.pdf'), findsOneWidget);
    });

    testWidgets('未知块显示占位说明而不是消失', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DocumentView(
              noteId: 'note-1',
              blocks: <UiBlock>[UnknownBlock('hologram')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('暂时渲染不出来'),
        findsOneWidget,
        reason: '未知块必须留痕，不能让用户以为内容丢了',
      );
    });
  });
}
