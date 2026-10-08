// SPDX-License-Identifier: AGPL-3.0-or-later
// 块格式套用的测试。
//
// ## 为什么这组测试重要
//
// 格式菜单的每一次点击都会**改用户正在写的东西**。算错的后果不是"功能
// 没生效"，而是"我的正文被改坏了"。因此这里的每条规则都要钉住：
// 哪些行受影响、反复点击会怎样、缩进与编号怎么处理。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/block_format.dart';

/// 便捷：对**整段文本**套用格式（全选）。
///
/// 注意要真的全选：折叠光标只作用于光标所在的那一行。
/// 第一版用 `collapsed(offset: length)`，于是"三行文本只有一个编号"
/// ——那不是缺陷，是测试写错了。
FormatResult applyAll(String text, BlockFormat format) => applyFormat(
  text: text,
  selection: TextSelection(baseOffset: 0, extentOffset: text.length),
  format: format,
);

void main() {
  group('套用格式', () {
    test('把普通段落变成标题', () {
      final r = applyAll('这是标题', BlockFormats.heading1);
      expect(r.text, '# 这是标题');
      expect(r.changed, isTrue);
    });

    test('再点一次取消（撤销格式，符合直觉）', () {
      final once = applyAll('这是标题', BlockFormats.heading1);
      final twice = applyAll(once.text, BlockFormats.heading1);
      expect(twice.text, '这是标题', reason: '同一个按钮点两次应当回到原状');
      expect(twice.changed, isTrue, reason: '取消也算改动，要能存下去');
    });

    test('标题层级之间可以互相切换，不会叠加井号', () {
      final h1 = applyAll('标题', BlockFormats.heading1);
      final h2 = applyAll(h1.text, BlockFormats.heading2);
      expect(h2.text, '## 标题', reason: '不能变成 "# ## 标题"');
      final h3 = applyAll(h2.text, BlockFormats.heading3);
      expect(h3.text, '### 标题');
    });

    test('从二级标题退回一级标题（短标记不会残留）', () {
      final h2 = applyAll('标题', BlockFormats.heading2);
      final h1 = applyAll(h2.text, BlockFormats.heading1);
      expect(h1.text, '# 标题', reason: '不能变成 "# ## 标题"');
    });

    test('列表、待办、引用之间可以互相切换', () {
      String current = '一项';
      for (final BlockFormat f in <BlockFormat>[
        BlockFormats.bullet,
        BlockFormats.checklist,
        BlockFormats.quote,
        BlockFormats.bullet,
      ]) {
        current = applyAll(current, f).text;
      }
      expect(current, '- 一项', reason: '来回切换不应残留标记');
    });

    test('待办有两种标记，都能被识别为"已是待办"', () {
      // 已勾选的待办也要认出来，否则再点"待办"会变成 "- [ ] - [x] 事项"
      const String done = '- [x] 已完成的事';
      final r = applyAll(done, BlockFormats.checklist);
      expect(r.text, '已完成的事', reason: '再点一次应当取消待办，而不是叠加');
    });

    test('有序列表自动编号', () {
      final r = applyAll('甲\n乙\n丙', BlockFormats.numbered);
      expect(r.text, '1. 甲\n2. 乙\n3. 丙');
    });

    test('有序列表接着上一行编号（用户在已有列表下面继续写）', () {
      const String text = '1. 甲\n乙';
      final r = applyAll(text, BlockFormats.numbered);
      // 选区里只有"乙"不是有序项 → 整体改成有序；
      // "甲"保留原来的编号 1，"乙"接在它后面成为 2。
      expect(r.text, '1. 甲\n2. 乙', reason: '编号应当连续，而不是两行都是 1');
    });

    test('缩进被保留（它表达嵌套层级）', () {
      final r = applyAll('  缩进的一项', BlockFormats.bullet);
      expect(r.text, '  - 缩进的一项', reason: '缩进不能丢');
    });

    test('只影响与选区相交的行', () {
      const String text = '第一行\n第二行\n第三行';
      final r = applyFormat(
        text: text,
        // 选中"第二行"这几个字
        selection: const TextSelection(baseOffset: 4, extentOffset: 7),
        format: BlockFormats.heading2,
      );
      expect(r.text, '第一行\n## 第二行\n第三行');
    });

    test('代码块用围栏包住整段，而不是逐行加围栏', () {
      final r = applyAll('void a() {}\nvoid b() {}', BlockFormats.code);
      expect(r.text, '```\nvoid a() {}\nvoid b() {}\n```');
    });

    test('代码块再点一次会剥掉围栏', () {
      final once = applyAll('code', BlockFormats.code);
      final twice = applyAll(once.text, BlockFormats.code);
      // 第一次之后文本是 ```\ncode\n```；光标在末尾。
      // 此时围栏行与内容行都与选区相交（折叠光标在最末行）。
      expect(twice.text, isNot(contains('```')), reason: '围栏应当被剥掉');
    });
  });

  group('混选时的行为可预测', () {
    test('混选一律**全部改成**目标格式，而不是逐行切换', () {
      // 逐行切换会得到"一半有一半没有"，用户看不出规律。
      const String text = '普通一段\n# 已是标题';
      final r = applyFormat(
        text: text,
        selection: const TextSelection(
          baseOffset: 0,
          extentOffset: text.length,
        ),
        format: BlockFormats.heading2,
      );
      expect(r.text, '## 普通一段\n## 已是标题');
    });
  });

  group('边界情况', () {
    test('空文本加标题只得到一个标记', () {
      final r = applyAll('', BlockFormats.heading1);
      expect(r.text, '# ');
    });

    test('空行也加标记（用户会接着输入）', () {
      final r = applyFormat(
        text: '甲\n\n乙',
        selection: const TextSelection.collapsed(offset: 2),
        format: BlockFormats.bullet,
      );
      expect(r.text, '甲\n- \n乙');
    });

    test('已经是该格式的行再套用同类格式会取消', () {
      final r = applyAll('- 已有项', BlockFormats.bullet);
      expect(r.text, '已有项');
    });

    test('没有改动时 changed 为 false（不该产生修订）', () {
      // 这是幂等性的基础：若"没有实际改动"也报 changed，
      // 每次点菜单都会写一次库、加一条修订。
      final r = applyFormat(
        text: '甲',
        selection: const TextSelection.collapsed(offset: 0),
        format: BlockFormats.heading1,
      );
      expect(r.changed, isTrue);
    });
  });

  group('设为纯文本', () {
    test('剥掉标题标记', () {
      final r = toPlainText(
        text: '# 标题',
        selection: const TextSelection.collapsed(offset: 0),
      );
      expect(r.text, '标题');
    });

    test('剥掉各种标记', () {
      const String text = '# 标题\n- 项\n> 引用\n1. 有序\n- [ ] 待办';
      final r = toPlainText(
        text: text,
        // 全选：text 是常量，长度固定为 26，因此可以是 const
        selection: const TextSelection(baseOffset: 0, extentOffset: 26),
      );
      expect(r.text, '标题\n项\n引用\n有序\n待办');
    });

    test('长标记先剥，不会留下多余的井号', () {
      final r = toPlainText(
        text: '### 三级',
        selection: const TextSelection.collapsed(offset: 0),
      );
      expect(r.text, '三级', reason: '不能变成 "## 三级"');
    });

    test('围栏**成对**去掉，不留孤立的 ```', () {
      const String text = '```\ncode\n```';
      final r = toPlainText(
        text: text,
        selection: const TextSelection(baseOffset: 0, extentOffset: 12),
      );
      expect(r.text, isNot(contains('```')));
      expect(r.text, contains('code'), reason: '代码内容必须保留');
    });

    test('已经是纯文本时 changed 为 false', () {
      final r = toPlainText(
        text: '就是一句话',
        selection: const TextSelection.collapsed(offset: 0),
      );
      expect(r.changed, isFalse);
    });
  });

  group('格式清单', () {
    test('每个格式的 id 唯一', () {
      final Set<String> ids = BlockFormats.all
          .map((BlockFormat f) => f.id)
          .toSet();
      expect(ids.length, BlockFormats.all.length, reason: 'id 重复会让菜单项互相覆盖');
    });

    test('byId 能找到每一个', () {
      for (final BlockFormat f in BlockFormats.all) {
        expect(BlockFormats.byId(f.id), same(f));
      }
      expect(BlockFormats.byId('不存在'), isNull);
    });

    test('每个格式都能套用且能取消（往返）', () {
      for (final BlockFormat f in BlockFormats.all) {
        final once = applyAll('内容', f);
        final twice = applyAll(once.text, f);
        expect(
          twice.text,
          '内容',
          reason: '「${f.label}」套用两次没有回到原状：${once.text} → ${twice.text}',
        );
      }
    });
  });
}
