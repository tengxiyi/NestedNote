// SPDX-License-Identifier: AGPL-3.0-or-later
//! 通用对话框与上下文菜单。
//!
//! ## 为什么要有 `showContextMenu`
//!
//! 本项目最初的右键/长按菜单用的是 `showModalBottomSheet`（从底部弹出）。
//! 那是**移动端**的习惯；桌面端右键的预期是在**光标处**弹出菜单。
//!
//! 这不只是好看与否的问题：底部弹出会盖住内容、且需要眼睛移动到屏幕另一侧，
//! 而右键菜单出现在鼠标旁边，用户可以不移动视线就完成选择。
//!
//! ## 分隔线与危险项
//!
//! - `ContextMenuItem.divider()` 表达"这几项是一组"；
//! - `destructive: true` 把删除类操作标红——**视觉警告必须与语义一致**，
//!   如果"删除"和"重命名"看起来一样，用户迟早会点错。
//!   注意：本项目的"删除"只是软删（进回收站），因此用**警示色**而不是
//!   危险红，以免过度惊吓；真正的不可逆操作（回收站里的"彻底删除"）
//!   才用满强度红色 + 二次确认。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 上下文菜单里的一项。
class ContextMenuItem<T> {
  /// 普通项。
  const ContextMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.shortcut,
    this.destructive = false,
    this.enabled = true,
  }) : isDivider = false;

  /// 分隔线。
  const ContextMenuItem.divider()
    : value = null,
      label = '',
      icon = null,
      shortcut = null,
      destructive = false,
      enabled = false,
      isDivider = true;

  /// 选中时返回的值。分隔线为 `null`。
  final T? value;

  /// 显示文字。
  final String label;

  /// 左侧图标。
  final IconData? icon;

  /// 右侧快捷键提示（纯展示，不负责绑定）。
  final String? shortcut;

  /// 是否为危险操作（用警示色）。
  final bool destructive;

  /// 是否可点。**不可点就置灰，不要留一个点了没反应的项**。
  final bool enabled;

  /// 是否为分隔线。
  final bool isDivider;
}

/// 在**光标处**弹出上下文菜单，返回选中项的值。
///
/// 返回 `null` 表示用户点了别处关掉了菜单。
///
/// ## 位置处理
///
/// 用 `RelativeRect.fromLTRB` 给出相对于 overlay 的位置。
/// 菜单贴近窗口右/下边缘时由 `showMenu` 自行翻转——
/// 这是它相对于"自己算坐标"的主要好处，不必手写边界逻辑。
Future<T?> showContextMenu<T>(
  BuildContext context, {
  required List<ContextMenuItem<T>> items,
  String? title,
}) {
  // 取当前指针位置：右键菜单要出现在鼠标旁。
  // 键盘触发（如 Shift+F10）时没有指针位置，退回用整体居中。
  final RenderBox? overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  final Offset position = _lastPointerPosition ?? Offset.zero;

  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      (overlay?.size.width ?? 0) - position.dx,
      (overlay?.size.height ?? 0) - position.dy,
    ),
    items: <PopupMenuEntry<T>>[
      if (title != null && title.isNotEmpty)
        PopupMenuItem<T>(
          enabled: false,
          height: 34,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      for (final ContextMenuItem<T> item in items)
        if (item.isDivider)
          const PopupMenuDivider()
        else
          PopupMenuItem<T>(
            value: item.value,
            enabled: item.enabled,
            height: 38,
            child: _ContextMenuRow(item: item),
          ),
    ],
  );
}

/// 菜单项的一行：图标 + 文字 + 快捷键提示。
class _ContextMenuRow<T> extends StatelessWidget {
  const _ContextMenuRow({required this.item});

  final ContextMenuItem<T> item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color? color = !item.enabled
        ? theme.disabledColor
        : item.destructive
        ? theme.colorScheme.error
        : null;

    return Row(
      children: <Widget>[
        if (item.icon != null) ...<Widget>[
          Icon(item.icon, size: 17, color: color),
          const SizedBox(width: 10),
        ] else
          const SizedBox(width: 27),
        Expanded(
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
        if (item.shortcut != null) ...<Widget>[
          const SizedBox(width: 18),
          Text(
            item.shortcut!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ],
    );
  }
}

/// 最近一次指针位置。
///
/// ## 为什么要自己记
///
/// Flutter 没有公开"当前鼠标位置"的查询接口。右键菜单必须出现在光标处，
/// 因此用一个全局监听器记录。这比在每个可右键的组件上都包一层
/// `GestureDetector(onSecondaryTapDown: ...)` 简单得多——后者要在
/// 每个菜单调用点都传一次坐标，容易漏。
Offset? _lastPointerPosition;

/// 安装全局指针位置监听。在应用启动时调用一次。
///
/// 用 `Listener` 包住整个应用而不是 `MouseRegion`：
/// 前者能收到所有指针事件（包括按下），而右键菜单需要的是**按下时**的位置。
class PointerPositionTracker extends StatelessWidget {
  /// 构造。
  const PointerPositionTracker({required this.child, super.key});

  /// 子组件。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent event) =>
          _lastPointerPosition = event.position,
      onPointerHover: (PointerHoverEvent event) =>
          _lastPointerPosition = event.position,
      child: child,
    );
  }
}

/// 让用户输入一段文本。
///
/// 公开（非下划线开头）以便被测试直接复用。
///
/// `initial` 用于"重命名"场景：预填当前名称，用户改一部分即可。
/// 返回 `null` 表示取消；返回空串表示用户确认了空输入——
/// 调用方**必须**自己判断空串并拒绝（本函数不替调用方决定什么算合法）。
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String? initial,
}) async {
  final TextEditingController controller = TextEditingController(
    text: initial ?? '',
  );
  try {
    return await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          // 回车即确认：桌面端用户的直觉
          onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

/// 二次确认对话框，返回用户是否确认。
///
/// `confirmLabel` 刻意要求调用方显式传入（而不是默认"确定"）：
/// 不可逆操作上写"确定"是**没有信息量**的，用户会条件反射地按下去。
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
