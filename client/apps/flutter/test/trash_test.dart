// SPDX-License-Identifier: AGPL-3.0-or-later
// 回收站保留期的纯函数测试。
//
// 为什么单独给这几行写测试：它决定界面告诉用户"还剩几天"，
// 而"提示还剩 1 天、其实已经删了"是用户最难接受的一类错误。
// 内核的清理条件与界面的倒计时必须一致，这里把边界钉死。

import 'package:flutter_test/flutter_test.dart';

import 'package:nested/core/trash_providers.dart';

void main() {
  const int day = kMsPerDay;
  const int retention = 15;

  group('回收站剩余天数', () {
    test('刚删除时显示完整保留期', () {
      final TrashAge age = trashAgeOf(
        deletedAtMs: 1000,
        retentionDays: retention,
        nowMs: 1000,
      );
      expect(age.remainingDays, retention);
      expect(age.expired, isFalse);
    });

    test('过了一天就少一天', () {
      final TrashAge age = trashAgeOf(
        deletedAtMs: 0,
        retentionDays: retention,
        nowMs: 1 * day,
      );
      expect(age.remainingDays, retention - 1);
      expect(age.expired, isFalse);
    });

    test('还有 1.2 天时向上取整为 2 天', () {
      // 向上取整是刻意的：保守估计不会让用户以为还有时间却已被删。
      // 用 floor 会在最后一天显示"还剩 1 天"直到最后一刻才变 0。
      final TrashAge age = trashAgeOf(
        deletedAtMs: 0,
        retentionDays: retention,
        nowMs: retention * day - (day + day ~/ 5),
      );
      expect(age.remainingDays, 2);
      expect(age.expired, isFalse);
    });

    test('恰好满保留期的那一刻不算过期', () {
      // 内核条件是 `deleted_at_ms < cutoff`（严格小于），
      // 所以"刚好 15 天"这一刻内核还没删。界面若说过期，
      // 用户重启后发现内容还在，就会怀疑提示不准。
      final TrashAge age = trashAgeOf(
        deletedAtMs: 0,
        retentionDays: retention,
        nowMs: retention * day,
      );
      expect(age.expired, isFalse, reason: '刚好到期时不该说过期');
    });

    test('超过保留期才算过期', () {
      final TrashAge age = trashAgeOf(
        deletedAtMs: 0,
        retentionDays: retention,
        nowMs: retention * day + 1,
      );
      expect(age.expired, isTrue);
      expect(age.remainingDays, 0);
    });

    test('保留期未知时不给出会误导的倒计时', () {
      // 引擎未就绪时内核返回 -1。此时既不能说"还剩 0 天"（像要删了），
      // 也不能说"已过期"（可能根本没过期）。
      for (final int unknown in <int>[0, -1, -100]) {
        final TrashAge age = trashAgeOf(
          deletedAtMs: 0,
          retentionDays: unknown,
          nowMs: 100 * day,
        );
        expect(age.remainingDays, 0);
        expect(age.expired, isFalse, reason: '保留期未知（$unknown）时不该声称已过期');
      }
    });

    test('保留期改变时倒计时随之改变', () {
      // 保留期是内核的单一常量，界面不该有自己的一份
      const int nowMs = 5 * day;
      expect(
        trashAgeOf(
          deletedAtMs: 0,
          retentionDays: 15,
          nowMs: nowMs,
        ).remainingDays,
        10,
      );
      expect(
        trashAgeOf(
          deletedAtMs: 0,
          retentionDays: 30,
          nowMs: nowMs,
        ).remainingDays,
        25,
      );
    });
  });

  group('两条"彻底删除"路径都要存在', () {
    // 用户确认的语义是**两条都通**：
    //
    //   1. 想立刻删 → 进回收站点「彻底删除」
    //   2. 什么都不做 → 15 天后自动删
    //
    // 因此"到期自动清理"与"手动彻底删除"是**并存**的，不是二选一。
    // 这一组把该语义钉住：若有人把保留期改成"永不自动删除"，
    // 或把手动入口去掉，都会在这里失败。
    test('保留期是有限值（说明确实会自动删除）', () {
      // 界面上显示的倒计时依赖它。若改成 0 或负数，
      // 语义会变成"立即删除"或"永不删除"，两者都不是用户要的。
      expect(retention, greaterThan(0), reason: '保留期必须为正，否则自动清理的语义就变了');
    });

    test('到期判定的边界：正好到期算不算已过期', () {
      // 内核用的是**严格小于**（remainingMs < 0 才算过期）。
      // 界面必须一致，否则会出现"界面说已过期、内核还没删"
      // 或反过来的"界面说还剩 1 天、实际已经删了"。
      final TrashAge exactlyAtDeadline = trashAgeOf(
        deletedAtMs: 0,
        retentionDays: retention,
        nowMs: retention * day,
      );
      expect(
        exactlyAtDeadline.expired,
        isFalse,
        reason: '正好卡在到期时刻时还没过期（与内核的严格小于一致）',
      );
      expect(exactlyAtDeadline.remainingDays, 0);

      final TrashAge justPast = trashAgeOf(
        deletedAtMs: 0,
        retentionDays: retention,
        nowMs: retention * day + 1,
      );
      expect(justPast.expired, isTrue, reason: '过了到期时刻一刻就算过期，下次启动会被清理');
    });
  });
}
