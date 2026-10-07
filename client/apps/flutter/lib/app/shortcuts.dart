// SPDX-License-Identifier: AGPL-3.0-or-later
//! 快捷键的**唯一来源**。
//!
//! ## 为什么必须集中在一处
//!
//! 菜单项上要标注快捷键（"新建笔记　Ctrl+N"），而实际按键分发在别处。
//! 两处各写一份字符串，迟早会出现**菜单写着 Ctrl+D、按下去没反应**，
//! 或者反过来"按了有反应但菜单没说"。用户没法自己排查这种不一致。
//!
//! 因此：菜单标注与实际绑定**都引用这里**。改键只改这里一处。
//!
//! ## 为什么没有 F10 / F11 / Ctrl+F11
//!
//! 印象笔记用它们切换三栏，但用户明确不要——那几个键与 Windows
//! 系统功能（F10 激活菜单栏、F11 全屏）及其它软件冲突。
//! 改用 `Ctrl+1/2/3`，这三个键在浏览器与编辑器里都是"切标签页"，
//! 语义上贴近"切视图"，且几乎不会冲突。
//!
//! ## 为什么"没有实现的动作不绑键"
//!
//! 印象笔记的 `Ctrl+D` 打开字体对话框。我们还没有那个功能，
//! 因此**不预留**这个键。留一个按下去没反应的键，比没有这个键更糟——
//! 用户会以为软件坏了（与铁律 F5"禁止假按钮"是同一条原则）。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 一个快捷键：按键组合 + 给人看的标注文本。
///
/// 把两者绑在一起，是为了**让菜单标注不可能与实际绑定不一致**。
class AppShortcut {
  /// 构造。
  const AppShortcut(this.activator, this.label);

  /// 实际绑定的按键组合。
  final SingleActivator activator;

  /// 菜单上显示的文本（如 `Ctrl+N`）。
  final String label;
}

/// 全部快捷键。
///
/// 命名按**动作**而不是按键：这样改键时不必改调用方。
abstract final class AppShortcuts {
  // ---------------------------------------------------------------- 文件

  /// 新建笔记。
  static const AppShortcut newNote = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyN, control: true),
    'Ctrl+N',
  );

  /// 新建子笔记本。
  static const AppShortcut newChildNotebook = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true),
    'Ctrl+Shift+N',
  );

  /// 立即保存。
  ///
  /// 编辑器本来就有自动保存；这个键给"我想确定它已经存了"的用户。
  static const AppShortcut save = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyS, control: true),
    'Ctrl+S',
  );

  // ---------------------------------------------------------------- 编辑

  /// 撤销。
  static const AppShortcut undo = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyZ, control: true),
    'Ctrl+Z',
  );

  /// 重做。
  ///
  /// 同时绑 `Ctrl+Y` 与 `Ctrl+Shift+Z`：Windows 习惯前者，
  /// 跨平台习惯后者。两个都绑不会冲突，且各自都有用户。
  static const AppShortcut redo = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyY, control: true),
    'Ctrl+Y',
  );

  /// 重做的另一个键。
  static const AppShortcut redoAlt = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
    'Ctrl+Shift+Z',
  );

  /// 全选**正文**。
  ///
  /// 刻意与"全选列表"分开：`Ctrl+A` 在文本框里是原生行为，
  /// 我们不抢它；列表的全选走菜单项（没有快捷键）。
  static const AppShortcut selectAllInEditor = AppShortcut(
    SingleActivator(LogicalKeyboardKey.keyA, control: true),
    'Ctrl+A',
  );

  // ---------------------------------------------------------------- 查看

  /// 只显示笔记列表（隐藏编辑器）。
  static const AppShortcut viewListOnly = AppShortcut(
    SingleActivator(LogicalKeyboardKey.digit1, control: true),
    'Ctrl+1',
  );

  /// 只显示编辑器（隐藏笔记列表）。
  static const AppShortcut viewEditorOnly = AppShortcut(
    SingleActivator(LogicalKeyboardKey.digit2, control: true),
    'Ctrl+2',
  );

  /// 恢复三栏。
  static const AppShortcut viewThreePanes = AppShortcut(
    SingleActivator(LogicalKeyboardKey.digit3, control: true),
    'Ctrl+3',
  );

  /// 折叠/展开左侧笔记本栏。
  static const AppShortcut toggleSidebar = AppShortcut(
    SingleActivator(LogicalKeyboardKey.digit4, control: true),
    'Ctrl+4',
  );

  // ---------------------------------------------------------------- 帮助

  /// 快捷键一览。
  static const AppShortcut shortcutsHelp = AppShortcut(
    SingleActivator(LogicalKeyboardKey.f1),
    'F1',
  );

  /// 供快捷键一览对话框按**分组**展示。
  ///
  /// 分组的顺序就是给人读的顺序：先文件、再编辑、再查看。
  /// 每个元素是 `(分组名, 组内条目)`，条目是 `(标注, 说明)`。
  static List<(String, List<(String, String)>)> forHelpDialog() {
    return <(String, List<(String, String)>)>[
      (
        '文件',
        <(String, String)>[
          (newNote.label, '新建笔记'),
          (newChildNotebook.label, '新建子笔记本'),
          (save.label, '立即保存（平时会自动保存）'),
        ],
      ),
      (
        '编辑',
        <(String, String)>[
          (undo.label, '撤销'),
          ('${redo.label} / ${redoAlt.label}', '重做'),
          ('Ctrl+C / Ctrl+V / Ctrl+X', '复制 / 粘贴 / 剪切'),
          (selectAllInEditor.label, '全选正文'),
        ],
      ),
      (
        '查看',
        <(String, String)>[
          (viewListOnly.label, '只显示笔记列表'),
          (viewEditorOnly.label, '只显示编辑器'),
          (viewThreePanes.label, '恢复三栏'),
          (toggleSidebar.label, '折叠 / 展开笔记本栏'),
        ],
      ),
      ('帮助', <(String, String)>[(shortcutsHelp.label, '打开这个列表')]),
    ];
  }
}
