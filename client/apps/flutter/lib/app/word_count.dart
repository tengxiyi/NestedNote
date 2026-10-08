// SPDX-License-Identifier: AGPL-3.0-or-later
//! 字数统计——**按中文习惯**。
//!
//! ## 为什么不直接 `text.length`
//!
//! `String.length` 数的是 UTF-16 码元："你好abc" 得 5（碰巧对），
//! 但 "你好 world" 也得 8——中文用户说的"字数"不是这个意思。
//!
//! 中文排版工具（Word、WPS）的通行规则：
//!
//! - **每个 CJK 字符算 1 个字**（汉字、假名、谚文等）；
//! - **连续的西文字母/数字算 1 个词**（`hello` 是 1，不是 5）；
//! - **空白与标点不计**。
//!
//! 这样"今天读了 30 pages" 得出 8（4 个汉字 + 2 个词），
//! 与用户在其它软件里看到的数字一致——不一致才会有人来报"字数不对"。
//!
//! ## 为什么按 `runes` 而不是 `codeUnits`
//!
//! Dart 字符串是 UTF-16。CJK 扩展 B 区（生僻字，如"𠮷"）在 UTF-16 里
//! 是**两个**码元（代理对）。按码元数会把一个字数成两个，或者两个都
//! 落不进任何区间而被整个漏掉。按码位（`runes`）数，一个字就是一个字。

/// 一篇笔记的字数统计结果。
class WordCount {
  /// 构造。
  const WordCount({
    required this.characters,
    required this.paragraphs,
    required this.readingMinutes,
  });

  /// 字数（CJK 按字、西文按词，空白与标点不计）。
  final int characters;

  /// 段落数（非空行的行数）。
  final int paragraphs;

  /// 预计阅读分钟数（向上取整；空文本为 0）。
  final int readingMinutes;

  /// 给人看的摘要，如"128 字 · 约 1 分钟"。
  String get summary {
    if (characters == 0) {
      return '0 字';
    }
    return '$characters 字 · 约 $readingMinutes 分钟';
  }
}

/// 统计一段文本。
WordCount countWords(String text) {
  int characters = 0;
  int paragraphs = 0;
  bool inWord = false;

  for (final String line in text.split('\n')) {
    if (line.trim().isNotEmpty) {
      paragraphs++;
    }
    for (final int rune in line.runes) {
      if (_isCjk(rune)) {
        characters++;
        inWord = false;
      } else if (_isWordChar(rune)) {
        // 西文/数字：连续的一段只算 1 个词
        if (!inWord) {
          characters++;
          inWord = true;
        }
      } else {
        // 空白、标点、其它符号：断开词，但不计入字数
        inWord = false;
      }
    }
    // 换行也是词边界
    inWord = false;
  }

  final int minutes = characters == 0 ? 0 : (characters / 300).ceil();
  return WordCount(
    characters: characters,
    paragraphs: paragraphs,
    readingMinutes: minutes,
  );
}

/// 是否 CJK 统意文字（汉字 / 假名 / 谚文）。
bool _isCjk(int rune) {
  return (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意文字
      (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
      (rune >= 0x20000 && rune <= 0x2A6DF) || // 扩展 B（生僻字）
      (rune >= 0x3040 && rune <= 0x30FF) || // 日文假名
      (rune >= 0xAC00 && rune <= 0xD7AF) || // 谚文音节
      (rune >= 0xF900 && rune <= 0xFAFF); // 兼容表意文字
}

/// 是否西文字母 / 数字（构成一个"词"的字符）。
bool _isWordChar(int rune) {
  return (rune >= 0x30 && rune <= 0x39) || // 数字
      (rune >= 0x41 && rune <= 0x5A) || // 大写
      (rune >= 0x61 && rune <= 0x7A) || // 小写
      (rune >= 0xC0 && rune <= 0x24F); // 拉丁扩展（é、ü 等）
}
