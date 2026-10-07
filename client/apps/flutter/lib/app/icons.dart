// SPDX-License-Identifier: AGPL-3.0-or-later
//! 图标体系 —— 界面上每个图标含义的**单一来源**。
//!
//! ## 为什么要集中定义
//!
//! 图标散落在各处随手选，会同时坏掉两件事：
//!
//! 1. **差异性**：不同概念用了相近的图标，用户分不清。
//!    本项目实际发生过——所有层级的笔记本都用 `folder_outlined`，
//!    于是第 5 层子文件夹和第 1 层顶层笔记本长得完全一样，"多层级"白做了。
//! 2. **一致性**：同一概念在不同位置用了不同图标。
//!    本项目实际发生过——笔记本树里的"全部笔记"用 `all_inbox`（实心收件箱），
//!    而笔记列表里的每一行**根本没有图标**，两者谁代表"笔记"无从判断。
//!
//! 集中在一处之后，这两个性质可以被**测试**（见 `test/widget_test.dart`
//! 的"图标体系"分组），而不是靠肉眼评审。
//!
//! ## 视觉语言（四条规则）
//!
//! | 规则 | 内容 |
//! |---|---|
//! | **1. 按概念定形** | 形状只表达"这是什么"，不表达"在哪里"。同一概念在任何位置必须同形 |
//! | **2. 按层级定变体** | 同一概念的不同层级用**同一套图标的变体**（如实心/半开/开源文件夹），既区分又可辨认出"它们是同类" |
//! | **3. 状态用颜色** | 选中、回收站、置顶等**状态**只改颜色，不改形状——否则形状的语义会被稀释 |
//! | **4. 颜色只表达状态** | 正常的结构性图标用 `outline` 色，不与选中态抢注意力 |

import 'package:flutter/material.dart';

/// 各层级的文件夹图标（索引 = 层级深度）。
///
/// 同一个"文件夹"概念，用三种**可累进辨认**的形态表达层级：
///
/// - 第 0 层：`folder`（实心）——最高层，最"重"
/// - 第 1 层：`folder_open`（打开）——里面还有东西
/// - 第 2 层及更深：`folder_outlined`（轮廓）——越深越"轻"
///
/// 三者同属"文件夹"家族，因此用户能一眼看出**它们是同类**；
/// 形态不同，因此能区分**自己在哪一层**。这比"每层换一个不相干的图标"
/// 更好——后者会让人以为它们是不同的东西。
const List<IconData> kFolderIconsByDepth = <IconData>[
  Icons.folder,
  Icons.folder_open,
  Icons.folder_outlined,
];

/// 顶层笔记本的图标。
const IconData kNotebookRootIcon = Icons.folder;

/// 最深一档（第 2 层及更深）的文件夹图标。
const IconData kNotebookDeepIcon = Icons.folder_outlined;

/// 取某个层级对应的文件夹图标（超出表格范围时用最深一档）。
IconData folderIconForDepth(int depth) {
  if (depth < 0) {
    return kNotebookRootIcon;
  }
  if (depth >= kFolderIconsByDepth.length) {
    return kNotebookDeepIcon;
  }
  return kFolderIconsByDepth[depth];
}

/// "全部笔记"入口。
const IconData kAllNotesIcon = Icons.all_inbox;

/// 笔记（**任何位置都用它**：中栏列表、右栏标题、移动对话框）。
const IconData kNoteIcon = Icons.description_outlined;

/// 回收站中的笔记——同一形状，只改颜色（规则 3）。
const IconData kDeletedNoteIcon = kNoteIcon;

/// 回收站开关（未激活）。
///
/// 这就是"回收站"这个概念的唯一图标。不要为同一概念再取别名——
/// 两个名字指向同一字形只会让人以为它们是两个东西。
const IconData kRecycleBinIcon = Icons.delete_outline;

/// 回收站开关（已激活/正在显示回收站）。
///
/// 与 [kRecycleBinIcon] **同族但实心**：开关的"开/关"属于规则 2 的
/// "同一概念的不同状态"——用同一套图标的变体表达，比换一个不相干的图标更好认。
const IconData kRecycleBinActiveIcon = Icons.delete;

/// 笔记行上的"在回收站中"标记。
///
/// 刻意与 [kRecycleBinIcon] 不同：那个是**回收站这个位置**的图标
/// （出现在工具栏开关上），这里是**这篇笔记的状态**标记。
/// 两者字形相同会导致"这一行是回收站入口"的误读。
const IconData kInRecycleBinBadgeIcon = Icons.delete_sweep_outlined;

/// 新建笔记。
const IconData kNewNoteIcon = Icons.add;

/// 新建笔记本 / 子笔记本。
const IconData kNewNotebookIcon = Icons.create_new_folder_outlined;

/// 折叠 / 展开左栏。
const IconData kExpandSidebarIcon = Icons.menu;
const IconData kCollapseSidebarIcon = Icons.menu_open;

/// 引擎自检入口。
const IconData kDiagnosticsIcon = Icons.monitor_heart_outlined;

/// 保存状态（已保存）。
const IconData kSavedIcon = Icons.cloud_done_outlined;

/// 保存状态（正在保存）。
const IconData kSavingIcon = Icons.cloud_upload_outlined;

/// 保存状态（保存失败）。
const IconData kSaveFailedIcon = Icons.cloud_off_outlined;

/// 立即保存。
const IconData kSaveIcon = Icons.save_outlined;

/// 把笔记移动到其它笔记本。
const IconData kMoveIcon = Icons.drive_file_move_outline;

/// 恢复（从回收站）。
const IconData kRestoreIcon = Icons.restore;

/// 空状态：还没有笔记。
const IconData kEmptyNotesIcon = Icons.note_add_outlined;

/// 空状态：未选择笔记。
const IconData kEmptyReadingIcon = Icons.article_outlined;

/// 失败状态。
const IconData kErrorIcon = Icons.error_outline;

/// 加载成功。
const IconData kCheckIcon = Icons.check_circle;

/// 差异中一行的类型。
///
/// ## 为什么要"颜色 + 符号"双重表达（铁律 U 组）
///
/// 差异视图习惯用绿/红区分新增与删除，但**只靠颜色是不够的**：
/// 约 8% 的男性有红绿色觉障碍，他们看不出这两色的差别。
/// 因此每一行同时带 `+` / `−` 前景标记，两个通道各自独立可读。
///
/// 这里刻意用 ASCII 的 `+` 与 `-`（渲染时用 U+2212 减号以求美观），
/// 而不是"新增/删除"文字：前者是 diff 的通用约定，用户一眼就懂。
///
/// 修订历史入口（编辑器工具栏）。
const IconData kHistoryIcon = Icons.history;

/// 时间线上的一条修订。
const IconData kRevisionIcon = Icons.edit_outlined;

/// 时间线上最新的一条修订。
const IconData kRevisionLatestIcon = Icons.circle;

/// "新版本"标记（时间线上当前选中的那一版）。
///
/// 是函数而不是常量：它需要 `BuildContext` 取主题色。
/// 用函数而不是"在调用处拼一个 Container"，是为了让两个标记的样式只有一处定义。
Widget revisionBadge(BuildContext context, {required bool isNew}) =>
    _RevBadge(label: isNew ? '新' : '旧', strong: isNew);

/// 修订时间线上的小标记。
class _RevBadge extends StatelessWidget {
  const _RevBadge({required this.label, required this.strong});

  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: strong
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: strong
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
