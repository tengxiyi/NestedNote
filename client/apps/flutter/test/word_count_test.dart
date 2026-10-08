// SPDX-License-Identifier: AGPL-3.0-or-later
// 字数统计的测试。
//
// ## 为什么这些测试值得写
//
// "字数不对"是用户一定会核对的功能（他会在 Word 里数一遍来对比）。
// 规则错一点他就会发现，而且很难解释"为什么你数的是 5，Word 数的是 4"。

import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/word_count.dart';

void main() {
  group('CJK 按字计', () {
    test('纯中文逐字计数', () {
      expect(countWords('你好世界').characters, 4);
    });

    test('空白不计', () {
      // 中文之间夹多少空格都不改变字数
      expect(countWords('你好  世界').characters, 4);
      expect(countWords('你好\n\t世界').characters, 4);
    });

    test('中文标点不计', () {
      // 中文习惯里"字数"指内容量，逗号句号不算——与 Word 一致
      expect(countWords('你好，世界。').characters, 4);
    });

    test('生僻字（扩展 B 区）不会漏', () {
      // "𠮷"是扩展 B 区字符，UTF-16 里占两个码元。
      // 按 codeUnits 数会漏掉或数成两个；按 runes 数才是 1。
      expect(countWords('𠮷').characters, 1);
      expect(countWords('𠮷野家').characters, 3);
    });
  });

  group('西文按词计', () {
    test('连续字母算 1 个词', () {
      expect(countWords('hello').characters, 1);
      expect(countWords('hello world').characters, 2);
    });

    test('数字与字母混合的连续段算 1 个词', () {
      // v2(1 个词) + 版(1) + 本(1) = 3
      expect(countWords('v2 版本').characters, 3);
      // 2026(1 词) + 年(1) + 10(1 词) + 月(1) = 4
      expect(countWords('2026年10月').characters, 4);
    });

    test('标点断开词', () {
      // "a,b" 是两个词（逗号是边界），不是三个也不是一个
      expect(countWords('a,b').characters, 2);
    });
  });

  group('混合文本', () {
    test('中英混排', () {
      // 2 个汉字（用、写）+ 2 个词（dart、flutter）= 4
      expect(countWords('用 dart 写 flutter').characters, 4);
    });

    test('空文本为 0', () {
      final WordCount wc = countWords('');
      expect(wc.characters, 0);
      expect(wc.paragraphs, 0);
      expect(wc.readingMinutes, 0);
      expect(wc.summary, '0 字');
    });

    test('只有空白也是 0', () {
      expect(countWords('  \n\n  ').characters, 0);
    });
  });

  group('段落与阅读时长', () {
    test('段落数按非空行计', () {
      expect(countWords('甲\n\n乙\n丙').paragraphs, 3);
    });

    test('阅读时长向上取整', () {
      // 301 字按 300 字/分钟应为 2 分钟（ceil），不能显示 1
      final String long = '字' * 301;
      expect(countWords(long).readingMinutes, 2);
      expect(countWords('字' * 300).readingMinutes, 1);
    });

    test('summary 对空文本不显示"约 0 分钟"', () {
      expect(countWords('').summary, '0 字', reason: '"约 0 分钟"读起来像坏了');
    });

    test('summary 包含字数与时长', () {
      expect(countWords('你好世界').summary, '4 字 · 约 1 分钟');
    });
  });
}
