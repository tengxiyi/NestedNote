// SPDX-License-Identifier: AGPL-3.0-or-later
//! 块标记的定义与套用规则。
//!
//! ## 这一层在做什么
//!
//! 格式菜单的动作是"给选中的行加/去前缀标记"（`# `、`- [ ] `……）。
//!
//! 真正的存储是块模型，而**文本是块的投影**（见 `nested-model` 的
//! `text_projection`）。因此"加前缀"不是表面功夫：保存时前缀会被反解成
//! 真正的块类型，读回来又是同样的文本。
//!
//! ## 为什么不做成"直接改块"
//!
//! 用户看到的是文本，光标在文本里。若菜单去改块模型，就要自己回答
//! "光标在哪个块""选区跨了几个块""改完怎么回到界面"——而这些正是
//! `TextEditingController` 已经解决的事。
//!
//! 走文本的另一个好处：**与手工敲 `# ` 完全等价**，没有第二种语义，
//! 用户也不必理解"块"这个概念。

import 'package:flutter/widgets.dart';

/// 一种可套用的块格式。
@immutable
class BlockFormat {
  /// 构造。
  const BlockFormat({
    required this.id,
    required this.label,
    required this.prefix,
    this.orderedNumbers = false,
    this.fence = false,
  });

  /// 稳定标识（菜单项与测试都用它，不用下标——下标会随菜单顺序变动）。
  final String id;

  /// 菜单上显示的名字。
  final String label;

  /// 行首标记。
  ///
  /// 待办是特例：它有"未完成/已完成"两个标记，由调用方提供，
  /// 因此这里给的是未完成形态。
  final String prefix;

  /// 是否按行编号（有序列表：`1. ` `2. `……）。
  final bool orderedNumbers;

  /// 是否用代码围栏（```` ``` ````）**包住**整段，而不是逐行加前缀。
  final bool fence;

  /// 去掉自身标记后判定"这一行已经有该格式"用的前缀集合。
  List<String> get allPrefixes {
    if (orderedNumbers) {
      // 有序列表的编号各不相同，用正则判断（见 [hasFormat]）
      return const <String>[];
    }
    if (id == 'checklist') {
      return const <String>['- [ ] ', '- [x] ', '- [X] '];
    }
    return <String>[prefix];
  }

  /// 这一行是否已经是该格式。
  bool hasFormat(String line) {
    final String t = line.trimLeft();
    if (orderedNumbers) {
      // `1. ` 这类：数字 + `. `
      final int dot = t.indexOf('. ');
      if (dot <= 0) {
        return false;
      }
      return t.substring(0, dot).split('').every((String c) {
        return c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
      });
    }
    for (final String p in allPrefixes) {
      if (t.startsWith(p)) {
        return true;
      }
    }
    return false;
  }
}

/// 全部可套用的格式。
///
/// 顺序即菜单顺序：**块级从"大"到"小"**（标题 → 列表 → 待办 → 引用 → 代码），
/// 与用户心里"这段话是什么"的粒度一致。
abstract final class BlockFormats {
  /// 一级标题。
  static const BlockFormat heading1 = BlockFormat(
    id: 'h1',
    label: '一级标题',
    prefix: '# ',
  );

  /// 二级标题。
  static const BlockFormat heading2 = BlockFormat(
    id: 'h2',
    label: '二级标题',
    prefix: '## ',
  );

  /// 三级标题。
  static const BlockFormat heading3 = BlockFormat(
    id: 'h3',
    label: '三级标题',
    prefix: '### ',
  );

  /// 无序列表。
  static const BlockFormat bullet = BlockFormat(
    id: 'bullet',
    label: '无序列表',
    prefix: '- ',
  );

  /// 有序列表。
  static const BlockFormat numbered = BlockFormat(
    id: 'numbered',
    label: '有序列表',
    prefix: '1. ',
    orderedNumbers: true,
  );

  /// 待办。
  static const BlockFormat checklist = BlockFormat(
    id: 'checklist',
    label: '待办',
    prefix: '- [ ] ',
  );

  /// 引用。
  static const BlockFormat quote = BlockFormat(
    id: 'quote',
    label: '引用',
    prefix: '> ',
  );

  /// 代码块。
  static const BlockFormat code = BlockFormat(
    id: 'code',
    label: '代码块',
    prefix: '```',
    fence: true,
  );

  /// 全部格式，按菜单顺序。
  static const List<BlockFormat> all = <BlockFormat>[
    heading1,
    heading2,
    heading3,
    bullet,
    numbered,
    checklist,
    quote,
    code,
  ];

  /// 按 [id] 找格式；找不到返回 `null`。
  static BlockFormat? byId(String id) {
    for (final BlockFormat f in all) {
      if (f.id == id) {
        return f;
      }
    }
    return null;
  }
}

/// 「设为纯文本」用：把要剥掉的标记，长的在前。
///
/// **顺序很关键**：`## ` 必须排在 `# ` 前面，否则 `## 标题` 会被
/// 先当成 `# ` 剥成 `# 标题`（少剥一层，用户看到的是"没反应"）。
const List<String> kStrippablePrefixes = <String>[
  '###### ',
  '##### ',
  '#### ',
  '### ',
  '## ',
  '# ',
  '- [x] ',
  '- [X] ',
  '- [ ] ',
  '- ',
  '> ',
  '1. ',
];

/// 一次套用格式的**结果**。
///
/// 返回新文本而不是直接改 controller：让"算什么"与"怎么落到界面"
/// 分开，前者可以纯函数地测试，也不必构造 `TextEditingController`。
@immutable
class FormatResult {
  /// 构造。
  const FormatResult({
    required this.text,
    required this.selection,
    required this.changed,
  });

  /// 应用后的完整文本。
  final String text;

  /// 应用后应当设置的选区。
  final TextSelection selection;

  /// 是否真的改动了。`false` 时调用方不该标记为"已修改"。
  final bool changed;
}

/// 把 [format] 套用到 [text] 中与 [selection] 相交的行上。
///
/// ## 规则
///
/// - **已经全是该格式 → 取消它**（再点一次就是撤销格式，符合直觉）；
/// - 否则**全部改成该格式**（而不是"切换每一行"——那样混选时会得到
///   一半有一半没有的结果，用户看不出规律）；
/// - 只影响与选区相交的行，不动别的行；
/// - **折叠光标（没选中）只作用于光标所在的那一行**。
FormatResult applyFormat({
  required String text,
  required TextSelection selection,
  required BlockFormat format,
}) {
  // 代码块是**包住整段**的，判定与套用都与其他格式不同，单独处理。
  // （第一版把它混在"逐行加前缀"里，于是套用两次会叠出两层围栏。）
  if (format.fence) {
    return _applyFence(text: text, selection: selection);
  }

  final List<String> lines = text.split('\n');
  final _LineRange range = _rangeOf(text, selection);

  // **改文本之前**记下光标在原来那一行里的相对位置。
  // 标记加在行首会让整行右移，之后再也算不出这个值了。
  final int cursorRelative = selection.isCollapsed
      ? selection.start - _lineStartOffset(text, range.first)
      : 0;

  // 已经全是该格式？→ 取消
  bool allHave = true;
  for (int i = range.first; i <= range.last; i++) {
    if (!format.hasFormat(lines[i])) {
      allHave = false;
      break;
    }
  }

  // 有序列表的编号基准：
  // - 若选区第一行**本身已是有序项**，沿用它（避免"1. 甲 → 重新编号"）；
  // - 否则接着上一行数（用户在已有列表下面继续写时期望连续）。
  final int base =
      _numberOf(lines[range.first]) ?? _baseNumber(lines, range.first);

  for (int i = range.first; i <= range.last; i++) {
    final String line = lines[i];
    if (allHave) {
      lines[i] = _stripAny(line);
    } else {
      lines[i] = _withPrefix(line, format, i - range.first, base);
    }
  }

  final String result = lines.join('\n');
  final bool changed = result != text;
  return FormatResult(
    text: result,
    selection: _selectionFor(result, range, selection, cursorRelative),
    changed: changed,
  );
}

/// 用围栏包住选区，或把已有的围栏去掉。
///
/// 围栏在块模型里对应 `Block::Code`，是**一个块**而不是每行一个，
/// 因此这里是"包住整段"而不是"逐行加围栏"。
FormatResult _applyFence({
  required String text,
  required TextSelection selection,
}) {
  final List<String> lines = text.split('\n');
  final _LineRange range = _rangeOf(text, selection);

  // 选区**内部**是否已有围栏（例如用户手动敲过，或上次套用的结果）
  final bool fencedInside = _hasFenceInside(lines, range);

  final List<String> out = <String>[];
  if (fencedInside) {
    // 已有围栏 → 去掉它们（连同选区内部的零星围栏）
    for (int i = 0; i < lines.length; i++) {
      if (i >= range.first && i <= range.last && _isFence(lines[i])) {
        continue;
      }
      out.add(lines[i]);
    }
  } else {
    out.addAll(lines.sublist(0, range.first));
    out.add('```');
    out.addAll(lines.sublist(range.first, range.last + 1));
    out.add('```');
    out.addAll(lines.sublist(range.last + 1));
  }

  final String result = out.join('\n');
  return FormatResult(
    text: result,
    selection: TextSelection.collapsed(offset: selection.start),
    changed: result != text,
  );
}

/// 选区内部是否含围栏行。
bool _hasFenceInside(List<String> lines, _LineRange range) {
  for (int i = range.first; i <= range.last; i++) {
    if (_isFence(lines[i])) {
      return true;
    }
  }
  return false;
}

/// 这一行是不是代码围栏。
bool _isFence(String line) => line.trimLeft().startsWith('```');

/// 与选区相交的行范围（含首含尾）。
class _LineRange {
  const _LineRange(this.first, this.last);

  final int first;
  final int last;
}

_LineRange _rangeOf(String text, TextSelection selection) {
  final int first = _lineOfOffset(text, selection.start);
  final int rawLast = _lineOfOffset(text, selection.end);
  // 选区终点正好落在某行行首时，不该把那一行也算进来
  //（用户只是拖到了下一行的开头）
  final int last =
      (rawLast > first && selection.end == _lineStartOffset(text, rawLast))
      ? rawLast - 1
      : rawLast;
  return _LineRange(first, last);
}

/// 某一行的有序编号；不是有序项则返回 `null`。
int? _numberOf(String line) {
  final String t = line.trimLeft();
  final int dot = t.indexOf('. ');
  if (dot <= 0 || dot > 9) {
    return null;
  }
  for (final int unit in t.substring(0, dot).codeUnits) {
    if (unit < 0x30 || unit > 0x39) {
      return null;
    }
  }
  return int.tryParse(t.substring(0, dot));
}

/// 有序列表的起始编号：若上一行是有序项，就接着它数。
int _baseNumber(List<String> lines, int first) {
  if (first <= 0) {
    return 1;
  }
  final int? above = _numberOf(lines[first - 1]);
  return above == null ? 1 : above + 1;
}

/// 「设为纯文本」：剥掉所有可识别的块标记。
FormatResult toPlainText({
  required String text,
  required TextSelection selection,
}) {
  final List<String> lines = text.split('\n');
  final int firstLine = _lineOfOffset(text, selection.start);
  final int lastLine = _lineOfOffset(text, selection.end);
  final int end =
      (lastLine > firstLine &&
          selection.end == _lineStartOffset(text, lastLine))
      ? lastLine - 1
      : lastLine;

  // 代码围栏是**成对**的，单独剥一行会留下孤立的 ```。
  // 因此先把整个选区里的围栏行找出来一并去掉。
  final Set<int> fenceLines = <int>{};
  for (int i = firstLine; i <= end; i++) {
    if (lines[i].trimLeft().startsWith('```')) {
      fenceLines.add(i);
    }
  }

  for (int i = firstLine; i <= end; i++) {
    if (fenceLines.contains(i)) {
      lines[i] = '';
      continue;
    }
    lines[i] = _stripAny(lines[i]);
  }

  final String result = lines.join('\n');
  return FormatResult(
    text: result,
    selection: TextSelection.collapsed(offset: selection.start),
    changed: result != text,
  );
}

// ------------------------------------------------------------------ 内部

/// 给一行加上格式标记。
///
/// ## 契约（这里踩过一次坑）
///
/// [_stripAny] 返回的是**含缩进的整行**（它要能直接替换原文）。
/// 本函数要的是"去缩进后的内容"，因此必须自己把缩进剥掉再拼回去——
/// 直接把 `_stripAny` 的结果接在缩进后面，缩进就被算了两遍：
/// `'  甲'` 会变成 `'  -   甲'`（三处空格）。
String _withPrefix(String line, BlockFormat format, int index, int base) {
  final String indent = _indentOf(line);
  final String body = _stripAny(line).substring(indent.length);
  if (format.orderedNumbers) {
    return '$indent${base + index}. $body';
  }
  return '$indent${format.prefix}$body';
}

/// 剥掉行首的任意可识别标记。
String _stripAny(String line) {
  final String indent = _indentOf(line);
  final String rest = line.substring(indent.length);
  // 长的在前，避免 `## ` 被 `# ` 先匹配（见 kStrippablePrefixes 的说明）
  for (final String p in kStrippablePrefixes) {
    if (rest.startsWith(p)) {
      return indent + rest.substring(p.length);
    }
  }
  // 有序列表的数字各不相同，单独处理
  final int dot = rest.indexOf('. ');
  if (dot > 0 && dot <= 9) {
    final String digits = rest.substring(0, dot);
    bool allDigits = true;
    for (final int unit in digits.codeUnits) {
      if (unit < 0x30 || unit > 0x39) {
        allDigits = false;
        break;
      }
    }
    if (allDigits) {
      return indent + rest.substring(dot + 2);
    }
  }
  return line;
}

/// 行首缩进（空格与制表符）。缩进要保留——它表达嵌套层级。
String _indentOf(String line) {
  int i = 0;
  while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
    i++;
  }
  return line.substring(0, i);
}

/// 某个偏移在文本里的行号（0 基）。
int _lineOfOffset(String text, int offset) {
  final int limit = offset.clamp(0, text.length);
  int line = 0;
  for (int i = 0; i < limit; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
    }
  }
  return line;
}

/// 某一行的起始偏移。
int _lineStartOffset(String text, int line) {
  if (line <= 0) {
    return 0;
  }
  int seen = 0;
  for (int i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      seen++;
      if (seen == line) {
        return i + 1;
      }
    }
  }
  return text.length;
}

/// 套用后应设置的选区。
///
/// [relativeOffset] 是**光标在原来那一行里的相对位置**（行首为 0），
/// 由调用方在改文本**之前**算好。标记加在行首会让整行右移，
/// 用相对位置才能让光标跟着文字走；用绝对偏移会让它停在文字中间。
TextSelection _selectionFor(
  String text,
  _LineRange range,
  TextSelection original,
  int relativeOffset,
) {
  final int start = _lineStartOffset(text, range.first);
  if (original.isCollapsed) {
    // 折叠光标保持折叠，不要突然选住一整行：
    // 用户只是想把当前行变成标题，不是想选中它。
    return TextSelection.collapsed(
      offset: (start + relativeOffset).clamp(0, text.length),
    );
  }
  final int endOfLast = _lineStartOffset(text, range.last + 1);
  return TextSelection(
    baseOffset: start,
    extentOffset: endOfLast > start ? endOfLast - 1 : start,
  );
}
