// SPDX-License-Identifier: AGPL-3.0-or-later
//! 排版：字体栈与字重口径。
//!
//! ## 为什么需要显式指定字体（一个真实的显示缺陷）
//!
//! 用户问："界面中显示的中文字为什么会有粗细？"
//!
//! 排查结论：**我们从来没有指定过字体**，而 Flutter 的 Material 排版
//! 把 `fontFamily` 写死成了 `'Roboto'`——**Roboto 没有中文字形**。
//!
//! 于是每个中文字符都要靠**字体回退**去系统里找一个能画的字体，
//! 而回退的结果在不同字号、不同对话框、不同控件里**并不稳定**：
//! 有时落到常规体，有时落到另一套字族，有时被合成加粗。
//! 结果就是同一句中文在界面各处粗细不一。
//!
//! 修法是**不让回退来决定**：显式给出一个真正含中文字形的字体，
//! 并让整套 `textTheme` 都从它派生。
//!
//! ## 为什么用字体栈而不是单个字体名
//!
//! 本应用目前只发布 Windows 版，但代码不该写死到"只有装了某字体才好看"：
//!
//! - `Noto Sans SC`：Windows 10 1709+ 随系统提供（也可以随包分发）；
//!   它的字重覆盖最全（Thin → Black），因此**字重差异能真实呈现**；
//! - `Microsoft YaHei UI`：所有中文 Windows 都有，兜底；
//! - `思源黑体 CN` / `PingFang SC`：分别覆盖装了思源的环境与 macOS；
//! - `sans-serif`：最后的通用兜底。
//!
//! `fontFamilyFallback` 是**有序**的：Flutter 逐个尝试，用第一个能画出
//! 该字符的字体。因此顺序本身就是"优先级"。
//!
//! ## 字重口径
//!
//! 顺带统一了强调字重：项目里原本 `w600` 与 `bold`（等价 `w700`）混用。
//! 在只有常规/粗体两档的字体上这两者会**渲染成同一个样子**，
//! 于是"两处都做了强调、看起来却不同"或者反过来。
//! 现在只有一个 [kEmphasisWeight]，需要强调就引用它。

import 'package:flutter/material.dart';

/// 首选字体。
///
/// ## 为什么是微软雅黑而不是 Noto Sans SC
///
/// 本机注册表查到的实际情况：
///
/// | 字体 | 注册形态 |
/// |---|---|
/// | `Microsoft YaHei` + `Microsoft YaHei UI` | `msyh.ttc` + **`msyhbd.ttc`（粗体）** + `msyhl.ttc`（细体）——**三个静态文件**，Windows 明确知道它们是一个字族的三个字重 |
/// | `Noto Sans SC` | `NotoSansSC-VF.ttf`——**单个可变字体文件**，字重靠内部轴表达 |
///
/// 可变字体字重覆盖更全（Thin → Black），看起来更"高级"，但它有个
/// 现实风险：**若渲染层没有正确解析字重轴，所有字重会渲染成同一个样子**。
/// 对一个"界面中文粗细不一致"的缺陷来说，那正好是从一个极端走到另一个极端。
///
/// 微软雅黑是三个真实存在的静态字重文件，Windows 与 Flutter 对它的解析
/// 没有歧义；它是中文 Windows 的系统界面字体，也正是用户在**其它软件里
/// 看惯了的样子**。因此把它放在首位。
///
/// Noto Sans SC 留在回退链靠前的位置：装了它但没装雅黑的环境（以及
/// 以后随包分发字体时）仍然能正确显示中文。
const String kFontFamily = 'Microsoft YaHei UI';

/// 回退链（有序，Flutter 逐个尝试）。
///
/// 顺序即优先级：越靠前越优先。最后一项是无法匹配时的通用兜底。
const List<String> kFontFamilyFallback = <String>[
  'Microsoft YaHei',
  'Noto Sans SC',
  '思源黑体 CN',
  'Source Han Sans SC',
  'PingFang SC',
  'Hiragino Sans GB',
  'SimHei',
  'sans-serif',
];

/// 唯一的强调字重。
///
/// 用 `w600` 而不是 `bold`：`bold` 是 `w700`，在中文黑体上常常直接被
/// 映射到同一个粗体档，两者视觉上无差别却写着两个值——
/// 后来者会以为它们有意不同，于是继续分叉。
///
/// 强调的**手段不止字重**：需要区分层级时优先用颜色与字号
/// （见 `docs` 的界面规则），字重变化过多会让整屏显得嘈杂。
const FontWeight kEmphasisWeight = FontWeight.w600;

/// 依据系统可用字体构造文本主题。
///
/// 从 [Typography.material2021] 派生而不是从零构造：Material 3 的
/// 字号/行高是成套调过的，自己重写一遍必然漏掉几档。
TextTheme buildTextTheme(Brightness brightness) {
  final Typography typography = Typography.material2021(
    platform: TargetPlatform.windows,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF3F6B5C),
      brightness: brightness,
    ),
  );
  final TextTheme base = brightness == Brightness.dark
      ? typography.white
      : typography.black;

  // `apply` 会把 fontFamily 与 fallback 铺到**每一档**上。
  // 逐个 `copyWith` 是做不到的：`TextTheme` 有 15 档，
  // 漏掉任何一档都会回到"由回退决定"的老问题。
  return base.apply(
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFamilyFallback,
  );
}
