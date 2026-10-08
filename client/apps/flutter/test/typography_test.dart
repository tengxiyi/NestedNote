// SPDX-License-Identifier: AGPL-3.0-or-later
// 排版的一致性与"中文必须有明确字体"这两件事的回归测试。
//
// ## 为什么值得单独测
//
// 用户报的现象是"界面里的中文字有粗有细"。根因是**我们从没指定过字体**，
// 而 Material 排版把 `fontFamily` 写死成 `'Roboto'`——Roboto 没有中文字形，
// 于是每个中文字都靠**字体回退**去系统里找，回退结果在不同字号/控件下
// 不稳定，表现为粗细不一。
//
// 这类缺陷不会让任何功能失败，因此**不会被功能测试抓住**；
// 它只在用户盯着界面看的时候暴露。所以这里用断言把它钉住。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nestednote/app/typography.dart';

void main() {
  group('字体栈', () {
    test('首选字体不是 Roboto（没有中文字形）', () {
      expect(
        kFontFamily,
        isNot('Roboto'),
        reason:
            'Roboto 画不出中文，选它等于把中文交给回退，'
            '而回退不稳定 → 中文粗细不一',
      );
    });

    test('首选字体在中文 Windows 上必然存在', () {
      // 首选必须是"不用装就有"的字体，否则在干净机器上又会掉回回退——
      // 那正是这个缺陷的成因。
      expect(
        kFontFamily,
        anyOf(contains('YaHei'), contains('SimHei'), contains('SimSun')),
        reason: '首选必须是中文 Windows 自带的字体',
      );
    });

    test('回退链覆盖常见中文 Windows 与 macOS', () {
      // 回退链是**有序**的，越靠前越优先。这里只断言关键成员都在，
      // 不断言具体顺序——顺序调整是合理的，缺少某平台的字才是缺陷。
      expect(
        kFontFamilyFallback,
        anyOf(contains('YaHei'), contains('SimHei')),
        reason: '所有中文 Windows 都有它们，是必须的兜底',
      );
      expect(
        kFontFamilyFallback.any((String f) => f.contains('PingFang')),
        isTrue,
        reason: 'macOS 的中文默认字体',
      );
      expect(
        kFontFamilyFallback,
        contains('sans-serif'),
        reason: '无论如何都要有一项通用兜底，否则缺失字体会掉到豆腐块',
      );
    });

    test('回退链自身不含首选字体（重复没有意义）', () {
      expect(
        kFontFamilyFallback,
        isNot(contains(kFontFamily)),
        reason: '首选已经在最前面了，回退里再来一次只会让人以为顺序有讲究',
      );
    });
  });

  group('文本主题', () {
    test('**每一档**都带上了字体与回退', () {
      // 这是核心：`TextTheme` 有 15 档，漏掉任何一档就会回到
      // "由回退决定"的老问题，而漏掉的那一档偏偏就是用户看到粗细不一的地方。
      final TextTheme theme = buildTextTheme(Brightness.light);
      final List<TextStyle?> styles = <TextStyle?>[
        theme.displayLarge,
        theme.displayMedium,
        theme.displaySmall,
        theme.headlineLarge,
        theme.headlineMedium,
        theme.headlineSmall,
        theme.titleLarge,
        theme.titleMedium,
        theme.titleSmall,
        theme.bodyLarge,
        theme.bodyMedium,
        theme.bodySmall,
        theme.labelLarge,
        theme.labelMedium,
        theme.labelSmall,
      ];

      for (int i = 0; i < styles.length; i++) {
        final TextStyle? style = styles[i];
        expect(style, isNotNull, reason: '第 $i 档不该为空');
        expect(
          style!.fontFamily,
          kFontFamily,
          reason: '第 $i 档的 fontFamily 不是首选字体',
        );
        expect(
          style.fontFamilyFallback,
          kFontFamilyFallback,
          reason: '第 $i 档缺少回退链',
        );
      }
    });

    test('浅色与深色主题都铺到了', () {
      for (final Brightness b in Brightness.values) {
        final TextTheme theme = buildTextTheme(b);
        expect(theme.bodyMedium?.fontFamily, kFontFamily, reason: '$b');
        expect(theme.titleSmall?.fontFamily, kFontFamily, reason: '$b');
      }
    });
  });

  group('字重口径', () {
    test('强调字重是 w600 而不是 w700', () {
      // 项目里原本 `w600` 与 `bold`(w700) 混用。在只有常规/粗体两档的
      // 中文字体上这两者会渲染成同一个样子，于是"两处都做了强调、
      // 看起来却不同"或者反过来。统一成一个值。
      expect(kEmphasisWeight, FontWeight.w600);
      expect(
        kEmphasisWeight,
        isNot(FontWeight.bold),
        reason: 'bold 是 w700；两个都留着就会继续分叉',
      );
    });
  });
}
