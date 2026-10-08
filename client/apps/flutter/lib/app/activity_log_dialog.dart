// SPDX-License-Identifier: AGPL-3.0-or-later
//! 活动日志对话框（M3 特色 4）。
//!
//! ## 回答的问题
//!
//! "这个应用对我的数据做了什么？"——回收站自动清理、附件 GC、
//! 完整性核对，这三类事件发生时用户通常不在场（或根本不知道有这回事）。
//! 本对话框把它们按时间倒序摆出来，每条是"时间 + 事件类型 + 一句
//! 含数字的说明"。
//!
//! ## 为什么只有这三类
//!
//! 笔记级变更修订历史已经完整记录（每次保存一条，含内容快照），
//! 这里再记一遍是噪音。刻意收窄到**维护/破坏性**事件——
//! 那是铁律 T1 唯一"用户没操作、数据却变化"的盲区。
//!
//! ## 空列表的文案
//!
//! FFI 层无法区分"没有记录"与"读取失败"，所以文案必须**两种情况
//! 都读得通**："还没有记录"+ 提示哪些操作会留痕。它不说"一切正常"
//! ——那是在把未知伪装成良好状态。

import 'package:flutter/material.dart';

import '../core/maintenance_providers.dart' as maintenance;
import 'note_list_pane.dart' show formatAbsoluteTime;
import 'typography.dart';

/// 打开活动日志。
Future<void> showActivityLogDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => const _ActivityLogDialog(),
  );
}

/// 事件类型 → 界面名称。
///
/// 内核的 kind 是稳定字符串（可检索），这里是唯一的展示映射。
/// 出现未知类型（内核先于界面升级）时**原样显示**并提示更新——
/// 藏起来等于撒谎。
String activityKindLabel(String kind) {
  return switch (kind) {
    'trash.purge' => '回收站清理',
    'attachments.gc' => '附件清理',
    'integrity.check' => '完整性核对',
    _ => kind,
  };
}

class _ActivityLogDialog extends StatelessWidget {
  const _ActivityLogDialog();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 上限给 200：日志按现有写入频率（手动维护）一年几百条，
    // 对话框只需要"最近的"，真正要翻旧账的场景应该去数据库。
    final Future<List<maintenance.ActivityEntry>> loading = maintenance
        .listActivity(200);

    return AlertDialog(
      title: const Text('活动日志'),
      content: SizedBox(
        width: 520,
        height: 380,
        child: FutureBuilder<List<maintenance.ActivityEntry>>(
          future: loading,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<maintenance.ActivityEntry>> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text(
                    '活动日志读取失败：${snapshot.error}\n\n'
                    '这不影响你的数据——只是这次没读出来。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  );
                }
                final List<maintenance.ActivityEntry> items =
                    snapshot.data ?? const <maintenance.ActivityEntry>[];
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      '还没有记录。\n\n'
                      '清理回收站、附件清理、完整性核对都会在这里留痕。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int index) {
                    final maintenance.ActivityEntry event = items[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            width: 118,
                            child: Text(
                              // 精确到分钟：日志要回答的是"什么时候"，相对时间
                              // （"3 天前"）会随时间漂移，回溯时没法用
                              formatAbsoluteTime(event.atMs),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 76,
                            child: Text(
                              activityKindLabel(event.kind),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: kEmphasisWeight,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              event.detail,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
