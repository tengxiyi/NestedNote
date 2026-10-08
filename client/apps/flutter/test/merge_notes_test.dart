// SPDX-License-Identifier: AGPL-3.0-or-later
// 合并文本组合规则的测试。
//
// ## 为什么值得测
//
// 合并是"把用户的多篇笔记重新排版"。规则错了（分隔线数量不对、
// 标题被吞、空笔记消失）就是**内容呈现层的数据损失**——虽然原笔记
// 还在，但产物是错的。

import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/merge_notes.dart';

void main() {
  group('composeMergedText', () {
    test('两篇：标题 + 正文 + 分隔线 + 标题 + 正文', () {
      final String text = composeMergedText(<(String, String)>[
        ('甲', '甲的内容'),
        ('乙', '乙的内容'),
      ]);
      expect(text, '# 甲\n甲的内容\n\n---\n\n# 乙\n乙的内容');
    });

    test('三篇恰好两条分隔线（不是更多或更少）', () {
      final String text = composeMergedText(<(String, String)>[
        ('甲', '一'),
        ('乙', '二'),
        ('丙', '三'),
      ]);
      expect('---'.allMatches(text).length, 2, reason: '分隔线 = 篇数 - 1');
      expect(text, startsWith('# 甲'), reason: '第一篇前没有分隔线');
    });

    test('空笔记保留标题行（它确实被合并了）', () {
      final String text = composeMergedText(<(String, String)>[
        ('有内容', '正文'),
        ('空空如也', ''),
      ]);
      expect(text, contains('# 空空如也'), reason: '空笔记不能凭空消失');
      expect(text, endsWith('# 空空如也'));
    });

    test('正文首尾空白被清理（不产生多余空行）', () {
      final String text = composeMergedText(<(String, String)>[
        ('甲', '\n\n甲的内容\n\n'),
      ]);
      expect(text, '# 甲\n甲的内容', reason: '投影会把尾部空行归一，这里先清掉');
    });

    test('单篇也能组合（虽然入口要求至少两篇）', () {
      final String text = composeMergedText(<(String, String)>[('甲', '内容')]);
      expect(text, '# 甲\n内容');
      expect(text.contains('---'), isFalse, reason: '单篇不需要分隔线');
    });

    test('产物能被投影无损往返（标题与分隔线都是真实块）', () {
      // 合并产物保存时会走 text_to_blocks 反解。这里用"手动模拟"
      // 反解后的块形态钉住关键结构：标题行必须以 '# ' 开头、
      // 分隔线必须是独立的 '---' 行——这两个是投影的解析锚点。
      final String text = composeMergedText(<(String, String)>[
        ('会议记录', '要点一'),
        ('待办', '事项'),
      ]);
      final List<String> lines = text.split('\n');
      expect(lines.where((String l) => l == '---').length, 1);
      expect(lines.where((String l) => l.startsWith('# ')).length, 2);
    });
  });
}
