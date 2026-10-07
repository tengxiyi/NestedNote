// SPDX-License-Identifier: AGPL-3.0-or-later
// 修订对比的界面逻辑测试。
//
// ## 这里只测"会误导用户"的部分
//
// 差异算法本身在 `nested-model` 有 14 个纯测试。这里测的是界面层两件
// 容易出错、且一旦错了就会**误导用户**的事：
//
// 1. **缺快照的说明文案**——说错了用户会以为"这两版一样"；
// 2. **时间格式**——历史列表是靠时间定位版本的。

import 'package:flutter_test/flutter_test.dart';

import 'package:nested/app/revision_history.dart';
import 'package:nested/core/revision_providers.dart';

void main() {
  group('缺快照的说明', () {
    test('只缺旧版本时，指出是哪一版并给出下一步', () {
      const DiffMissingSnapshot missing = DiffMissingSnapshot(
        oldVersion: 2,
        newVersion: 5,
        oldMissing: true,
        newMissing: false,
      );
      final String text = missing.explanation;
      expect(text, contains('第 2 版'), reason: '必须说清是哪一版缺快照');
      expect(text, contains('请选择更新的版本'), reason: '只说"无法对比"没有用，要告诉用户怎么办');
    });

    test('只缺新版本时，指出是新版本缺', () {
      const DiffMissingSnapshot missing = DiffMissingSnapshot(
        oldVersion: 5,
        newVersion: 9,
        oldMissing: false,
        newMissing: true,
      );
      expect(missing.explanation, contains('第 9 版'));
    });

    test('两侧都缺时解释原因，而不是只说"无法对比"', () {
      const DiffMissingSnapshot missing = DiffMissingSnapshot(
        oldVersion: 1,
        newVersion: 2,
        oldMissing: true,
        newMissing: true,
      );
      final String text = missing.explanation;
      expect(text, contains('后来才加入'), reason: '要解释"为什么没有"，否则用户会以为是程序坏了');
    });

    test('说明文案绝不出现"相同""没有差异"这类措辞', () {
      // 这是最关键的一条：缺快照 = **我们不知道**，
      // 一旦文案里出现"相同"，用户就会得出"两版内容一样"的错误结论。
      // 而事实是那两版的内容我们根本没记录下来。
      for (final DiffMissingSnapshot missing in <DiffMissingSnapshot>[
        const DiffMissingSnapshot(
          oldVersion: 1,
          newVersion: 2,
          oldMissing: true,
          newMissing: false,
        ),
        const DiffMissingSnapshot(
          oldVersion: 1,
          newVersion: 2,
          oldMissing: false,
          newMissing: true,
        ),
        const DiffMissingSnapshot(
          oldVersion: 1,
          newVersion: 2,
          oldMissing: true,
          newMissing: true,
        ),
      ]) {
        final String text = missing.explanation;
        for (final String forbidden in <String>['相同', '没有差异', '内容一致']) {
          expect(
            text,
            isNot(contains(forbidden)),
            reason:
                '缺快照的说明里不得出现「$forbidden」——'
                '那会让用户以为两版内容一样，而事实是我们不知道',
          );
        }
      }
    });
  });

  group('修订时间格式', () {
    test('精确到分钟（同一天多次修改要能区分）', () {
      // 只显示日期的话，一天内改了三次会看起来完全一样，
      // 用户没法靠时间定位版本。
      final int ms = DateTime(2026, 3, 16, 14, 5).millisecondsSinceEpoch;
      expect(formatRevisionTime(ms), '2026-03-16 14:05');
    });

    test('月日时分都补零', () {
      final int ms = DateTime(2026, 1, 2, 3, 4).millisecondsSinceEpoch;
      expect(formatRevisionTime(ms), '2026-01-02 03:04');
    });
  });

  group('差异行', () {
    test('类型判定与标记一致', () {
      const DiffLine added = DiffLine(kind: 'added', text: 'a');
      const DiffLine removed = DiffLine(kind: 'removed', text: 'b');
      const DiffLine same = DiffLine(kind: 'unchanged', text: 'c');

      expect(added.isAdded, isTrue);
      expect(added.isRemoved, isFalse);
      expect(removed.isRemoved, isTrue);
      expect(removed.isAdded, isFalse);
      expect(same.isAdded, isFalse);
      expect(same.isRemoved, isFalse);
    });
  });

  group('差异结果', () {
    test('无增删即视为内容相同', () {
      const DiffContent content = DiffContent(
        oldVersion: 1,
        newVersion: 2,
        added: 0,
        removed: 0,
        lines: <DiffLine>[DiffLine(kind: 'unchanged', text: 'x')],
      );
      expect(content.identical, isTrue);
    });

    test('有增或有删都不算相同', () {
      expect(
        const DiffContent(
          oldVersion: 1,
          newVersion: 2,
          added: 1,
          removed: 0,
          lines: <DiffLine>[],
        ).identical,
        isFalse,
      );
      expect(
        const DiffContent(
          oldVersion: 1,
          newVersion: 2,
          added: 0,
          removed: 1,
          lines: <DiffLine>[],
        ).identical,
        isFalse,
      );
    });
  });
}
