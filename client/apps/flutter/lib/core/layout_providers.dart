// SPDX-License-Identifier: AGPL-3.0-or-later
//! 三栏的**显示模式**。
//!
//! ## 为什么需要它（而不是两个 bool）
//!
//! 三栏各自"显示/隐藏"可以组合出 4 种状态，但只有 3 种有意义：
//! 三栏全显、只看列表、只看正文。"笔记本栏与编辑器都显示、唯独藏掉列表"
//! 是没有意义的——那时用户既选不了笔记，列表又占着位置。
//!
//! 用两个 bool 就会让那一种无意义状态**可以被表示出来**，
//! 于是界面要处理它、测试要覆盖它、后来者要猜它意味着什么。
//! 枚举把"有意义的状态"变成类型本身的约束。
//!
//! ## 关于"隐藏笔记本栏"
//!
//! 它与这三种模式**正交**：任何模式下都可以折叠左栏（那是"腾地方"，
//! 不是"换视图"）。因此它单独一个 bool，不塞进枚举——
//! 塞进去会让状态数从 3 涨到 6，而其中 3 个只是同一件事的变体。
//! 这正是 `notes_page.dart` 里原有的 `_sidebarCollapsed`。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 三栏的显示模式。
enum PaneLayout {
  /// 三栏全显（默认）。
  threePanes,

  /// 只显示笔记列表——用于快速浏览、批量整理。
  ///
  /// 左栏仍在（要靠它换笔记本），隐藏的是编辑器。
  listOnly,

  /// 只显示编辑器——用于专注写作。
  ///
  /// 左栏与列表都隐藏。
  editorOnly,
}

/// 当前显示模式的持有者。
class PaneLayoutNotifier extends Notifier<PaneLayout> {
  @override
  PaneLayout build() => PaneLayout.threePanes;

  /// 切换模式。
  void set(PaneLayout layout) => state = layout;

  /// 设为"只显示列表"。
  void listOnly() => state = PaneLayout.listOnly;

  /// 设为"只显示编辑器"。
  void editorOnly() => state = PaneLayout.editorOnly;

  /// 恢复三栏。
  void threePanes() => state = PaneLayout.threePanes;
}

/// 显示模式。
final paneLayoutProvider = NotifierProvider<PaneLayoutNotifier, PaneLayout>(
  PaneLayoutNotifier.new,
);

/// 左侧笔记本栏是否折叠。
///
/// 与 [paneLayoutProvider] **正交**：折叠是"腾地方"，切模式是"换视图"。
/// 混在一起会让状态数翻倍，且其中一半是重复表达。
class SidebarCollapsedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 切换折叠状态。
  void toggle() => state = !state;

  /// 明确设置。
  void set(bool collapsed) => state = collapsed;
}

/// 左栏是否折叠。
final sidebarCollapsedProvider =
    NotifierProvider<SidebarCollapsedNotifier, bool>(
      SidebarCollapsedNotifier.new,
    );

// ------------------------------------------------------------------ 字号缩放

/// 编辑器正文字号的缩放倍率。
///
/// ## 为什么只缩放编辑器，而不缩放整个应用
///
/// 印象笔记的"缩放"缩的是整个窗口内容。对我们来说那是错的方向：
/// 界面文字（菜单、按钮、列表）的大小是设计好的，放大它们只会让
/// 布局变乱；用户想放大的是**正在读的正文**——那是他盯得最久的东西。
///
/// ## 边界为什么是 0.7–2.0
///
/// - 低于 0.7 时中文笔画开始粘连（小字号下微软雅黑的渲染质量下降）；
/// - 高于 2.0 时每行容纳的字太少，反而读不下去。
///
/// 越界请求直接**夹取**而不是报错——缩放是连续的手感动作，
/// 按住快捷键连按的人不希望被弹错误提示打断。
class EditorFontScaleNotifier extends Notifier<double> {
  /// 允许的最小倍率。
  static const double kMin = 0.7;

  /// 允许的最大倍率。
  static const double kMax = 2.0;

  /// 每次放大/缩小的步长。
  static const double kStep = 0.1;

  @override
  double build() => 1.0;

  /// 放大一档。
  void zoomIn() => set(state + kStep);

  /// 缩小一档。
  void zoomOut() => set(state - kStep);

  /// 恢复默认。
  void reset() => state = 1.0;

  /// 设置（夹取到合法区间）。
  void set(double value) {
    state = value.clamp(kMin, kMax);
  }
}

/// 编辑器正文字号倍率（1.0 = 默认）。
final editorFontScaleProvider =
    NotifierProvider<EditorFontScaleNotifier, double>(
      EditorFontScaleNotifier.new,
    );
