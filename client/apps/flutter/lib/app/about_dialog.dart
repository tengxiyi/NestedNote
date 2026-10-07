// SPDX-License-Identifier: AGPL-3.0-or-later
//! 关于对话框。
//!
//! ## 为什么"关于"里要放数据目录路径
//!
//! 绝大多数软件的"关于"只放版本号。但那对**排查问题**没什么用：
//! 用户遇到异常时最常需要回答的两个问题是"你用的是哪个版本"和
//! "数据存在哪里"。前者决定有没有那个修复，后者决定备份与取证从哪下手。
//!
//! 因此这里直接显示出来，并提供**一键复制**——
//! 否则用户要照着屏幕一个字一个字敲给维护者。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine.dart';
import '../core/engine_providers.dart';

/// 打开"关于"。
Future<void> showNestedAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => const _AboutDialog(),
  );
}

class _AboutDialog extends ConsumerWidget {
  const _AboutDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<EngineStatus> engine = ref.watch(engineProvider);
    // 显示名与版本都**从内核读**，不在 Dart 里另写一份：
    // 两处各写一份就会出现"关于里说 0.1.0、安装包里是 0.2.0"。
    final EngineStatus? status = engine.value;
    final String displayName = status?.displayName ?? '拾光笔记';
    final String? databasePath = status?.databasePath;

    return AlertDialog(
      title: Text(displayName),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '本地优先的多层级笔记应用。\n'
              '数据全部存在你自己的电脑上，不依赖任何网络服务。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            _row(context, '内核版本', status?.version ?? '—'),
            _row(context, '同步协议版本', status?.protocolVersion.toString() ?? '—'),
            _row(context, '引擎就绪', (status?.ready ?? false) ? '是' : '否'),
            const SizedBox(height: 10),
            // 数据库路径是排查与备份的起点，因此单独给一行 + 复制按钮。
            // 用 `SelectableText` 而不是普通 `Text`：用户可以手动选中一部分，
            // 不必非得点复制（有时他只想复制目录那一段）。
            Text('数据库位置', style: theme.textTheme.labelSmall),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    databasePath ?? '（引擎未就绪，暂时读不到）',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: '复制数据库路径',
                  visualDensity: VisualDensity.compact,
                  onPressed: databasePath == null
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: databasePath),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('路径已复制。')),
                            );
                          }
                        },
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                ),
              ],
            ),
            if (status?.message != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '引擎提示：${status!.message}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text('许可：AGPL-3.0-or-later', style: theme.textTheme.labelSmall),
          ],
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

  Widget _row(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Text(label, style: theme.textTheme.labelSmall),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
