// SPDX-License-Identifier: AGPL-3.0-or-later
//! 快捷键一览。
//!
//! ## 为什么必须有这个对话框
//!
//! 我们把快捷键集中在菜单栏（`shortcuts.dart`），但菜单栏只显示**当前可用项**
//! 的键。用户想知道"这软件一共有哪些键"时，得把四个菜单逐个展开——
//! 那不是"查阅"，那是"翻找"。
//!
//! 因此专门给一处集中的列表，并且**与 `AppShortcuts` 同源**：
//! 键改了这里自动跟着变，不会出现"对话框说 Ctrl+4、实际按 Ctrl+3"。

import 'package:flutter/material.dart';

import 'shortcuts.dart';
import 'typography.dart';

/// 打开快捷键一览。
Future<void> showShortcutsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => const _ShortcutsDialog(),
  );
}

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<(String, List<(String, String)>)> groups =
        AppShortcuts.forHelpDialog();

    return AlertDialog(
      title: const Text('快捷键'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final (String group, List<(String, String)> items)
                  in groups) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Text(
                    group,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: kEmphasisWeight,
                    ),
                  ),
                ),
                for (final (String keys, String what) in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // 键名列固定宽度：让说明文字**左对齐成一列**。
                        // 不定宽的话每一行的说明会跟着键名长度左右跳动，
                        // 一屏十几行看起来会很乱。
                        SizedBox(
                          width: 168,
                          child: Text(
                            keys,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(what, style: theme.textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
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
