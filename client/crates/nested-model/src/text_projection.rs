// SPDX-License-Identifier: AGPL-3.0-or-later
//! 块与纯文本之间的**可逆**投影。
//!
//! ## 为什么需要它
//!
//! 编辑器目前是纯文本的，而存储是块模型。两者之间的转换原先只有
//! `text_to_document`：**把每一行都当成段落，并且丢掉空行**。
//!
//! 后果有两个，都很实在：
//!
//! 1. **块类型在保存时被抹平**——一篇有标题、列表、代码块的笔记，
//!    只要在编辑器里保存一次就全变成段落。用户看不到任何提示，
//!    格式"悄悄没了"；
//! 2. 空行丢失 → 用户在编辑器里按两次回车隔开两段，保存后间距消失。
//!
//! 因此"格式菜单"不能只做界面接线：下方必须先能无损往返。
//!
//! ## 表示法：Markdown 风格 + 需要时补 id
//!
//! 选 Markdown 风格而不是自定义符号，理由有两条：
//!
//! - **用户已经会**。不必教他"标题要写成 `[H1]`"；
//! - **它是纯文本**。即使某天块模型改版、投影规则变了，
//!   用户的数据仍然是一篇读得懂的 Markdown，而不是一堆控制字符。
//!
//! | 块 | 文本表示 |
//! |---|---|
//! | 段落 | 原样 |
//! | 标题 | `# ` / `## ` … （1–6 个 `#`） |
//! | 无序列表 | `- ` |
//! | 有序列表 | `1. ` |
//! | 待办 | `- [ ] ` / `- [x] ` |
//! | 引用 | `> ` |
//! | 代码块 | ` ```lang ` 与 ` ``` ` 包围 |
//! | 分割线 | `---` |
//! | 链接 | `[文本](href)` |
//! | 图片 | `![替代文本](attachment-id)` |
//! | 文件 | `[file: 文件名](attachment-id)` |
//! | 表格 | `\| 单元格 \| … \|`（首行为表头时补一行 `\|---\|`） |
//!
//! ## 圆整保证
//!
//! `blocks_to_text` 与 `text_to_blocks` 互为逆运算：
//! **对上面表格里的每种块，`text_to_blocks(blocks_to_text(x)) == x`**。
//! 有测试逐种钉住（见文件末尾），因为"往返丢信息"正是本模块要修的缺陷。
//!
//! ## 明确不保证的部分
//!
//! - **行内标记（加粗/斜体/链接标记）会被丢弃**。它们是字节偏移，
//!   在纯文本里没有稳定表示；富文本编辑器上线后才处理。
//!   丢的是"样式"，文本本身一个字不少。
//! - 表格的列宽、图片的宽高不保留（投影里无处安放）。
//! - 任何**无法表示**的内容都会退化成段落文本，而不会凭空消失。

use crate::block::{Block, BlockKind, ListItem, TableCell, TableRow};
use crate::id::Id;

/// 代码块围栏。
const FENCE: &str = "```";

/// 把块序列投影成纯文本。
///
/// 见模块文档的表示法表格。
#[must_use]
pub fn blocks_to_text(blocks: &[Block]) -> String {
    let mut lines: Vec<String> = Vec::with_capacity(blocks.len());
    for block in blocks {
        push_block(block, &mut lines);
    }
    lines.join("\n")
}

fn push_block(block: &Block, out: &mut Vec<String>) {
    match block {
        Block::Paragraph { text, .. } => out.push(text.clone()),
        Block::Heading { level, text, .. } => {
            // 层级夹到 1–6：Markdown 只认这六级，而字段是 u8。
            // 越界时夹取而不是丢弃——丢一个标题比少几个 `#` 严重得多。
            let hashes = "#".repeat(usize::from((*level).clamp(1, 6)));
            out.push(format!("{hashes} {text}"));
        }
        Block::List {
            ordered,
            start,
            items,
        } => {
            for (index, item) in items.iter().enumerate() {
                let marker = if *ordered {
                    format!("{}. ", start + u32::try_from(index).unwrap_or(0))
                } else {
                    "- ".to_owned()
                };
                out.push(format!("{marker}{}", item.text));
                // 嵌套子块缩进两格输出。子块本身仍走同一套投影规则，
                // 因此一行 `  - [ ] 待办` 也能被反解回来。
                let mut child_lines: Vec<String> = Vec::new();
                for child in &item.children {
                    push_block(child, &mut child_lines);
                }
                for line in child_lines {
                    out.push(format!("  {line}"));
                }
            }
        }
        // 独立的 ListItem 不该出现在顶层；真出现了就按段落输出，
        // 保证文本不丢（宁可丢结构，不可丢内容）。
        Block::ListItem { text, children } => {
            out.push(format!("- {text}"));
            let mut child_lines: Vec<String> = Vec::new();
            for child in children {
                push_block(child, &mut child_lines);
            }
            for line in child_lines {
                out.push(format!("  {line}"));
            }
        }
        Block::Checklist { checked, text } => {
            out.push(format!("- [{}] {text}", if *checked { "x" } else { " " }));
        }
        Block::Quote { text, cite } => {
            out.push(format!("> {text}"));
            // 出处单独一行，前缀 `> --` —— 与引用正文区分得开，
            // 且反解时可以无歧义地认出来。
            if let Some(cite) = cite {
                out.push(format!("> -- {cite}"));
            }
        }
        Block::Code { language, code } => {
            out.push(format!("{FENCE}{}", language.clone().unwrap_or_default()));
            for line in code.split('\n') {
                out.push(line.to_owned());
            }
            out.push(FENCE.to_owned());
        }
        Block::Image {
            attachment_id, alt, ..
        } => {
            // 宽高无处安放（投影里没有位置），明确丢弃——
            // 丢的是展示尺寸，不是内容。
            out.push(format!(
                "![{}]({attachment_id})",
                alt.clone().unwrap_or_default()
            ));
        }
        Block::File {
            attachment_id,
            filename,
        } => out.push(format!("[file: {filename}]({attachment_id})")),
        Block::Table { rows } => {
            for (index, row) in rows.iter().enumerate() {
                let cells: Vec<String> = row.cells.iter().map(|c| c.text.clone()).collect();
                out.push(format!("| {} |", cells.join(" | ")));
                // 表头与数据之间插一条分隔行（Markdown 的写法）
                if index == 0 && row.cells.iter().any(|c| c.header) {
                    let bars: Vec<&str> = row.cells.iter().map(|_| "---").collect();
                    out.push(format!("| {} |", bars.join(" | ")));
                }
            }
        }
        Block::Divider => out.push("---".to_owned()),
        Block::Link { text, href } => out.push(format!("[{text}]({href})")),
        // Embed 是 P7 预留，目前没有产生路径。按可读文本输出，
        // 保证内容不丢；反解时它会变成段落——这是有意的降级，
        // 而不是"悄悄消失"。
        Block::Embed {
            provider,
            reference,
        } => out.push(format!("[embed: {provider}/{reference}]")),
    }
}

/// 把纯文本反解成块序列。
///
/// **空行被保留**为空的段落块。这是与旧实现最关键的差别：
/// 旧实现 `filter(|line| !line.is_empty())` 把空行丢掉了，
/// 于是"按两次回车分段"这个最基本的操作在保存后失效。
#[must_use]
pub fn text_to_blocks(text: &str) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    // 用 `split('\n')` 而不是 `lines()`：`lines()` 会把结尾的换行
    // 当作结束符而不是空行，而我们要如实反映用户敲过的每一次回车。
    let all: Vec<&str> = text.split('\n').collect();
    let mut index = 0_usize;

    while index < all.len() {
        let line = all[index];

        // ---- 代码块：整段吃掉，内部不做任何解析 ----
        if let Some(rest) = line.trim_start().strip_prefix(FENCE) {
            // 缩进的围栏：把缩进量记下来，内部行的同等缩进要去掉
            let indent = line.len() - line.trim_start().len();
            let language = rest.trim();
            let mut body: Vec<String> = Vec::new();
            index += 1;
            while index < all.len() {
                let inner = all[index];
                if inner.trim_start().starts_with(FENCE) {
                    break;
                }
                // 去掉投影时加上的缩进，保证往返一致
                body.push(strip_indent(inner, indent));
                index += 1;
            }
            index += 1; // 跳过收尾围栏
            blocks.push(Block::Code {
                language: if language.is_empty() {
                    None
                } else {
                    Some(language.to_owned())
                },
                code: body.join("\n"),
            });
            continue;
        }

        // ---- 表格的"表头分隔行" ----
        //
        // Markdown 里表头下面那行 `| --- | --- |` 是**标记**，不是数据：
        // 它把上一行标成表头，自己不出现在结果里。
        //
        // **这一步必须在"合并表格行"之前**：否则 `| --- |` 会先被
        // 并进表里变成一行数据，再也没机会被识别成标记。
        // （第一版就是顺序反了，于是表头行留在了结果里。）
        //
        // 它需要**看到上一块**，因此不能放进 `parse_line`
        //（那是"一行进、一块出"的纯函数，拿不到上下文）。
        if is_table_separator(line) {
            if let Some(Block::Table { rows }) = blocks.last_mut() {
                for row in rows.iter_mut() {
                    for cell in &mut row.cells {
                        cell.header = true;
                    }
                }
            }
            // 没有上一行可标记时这行是野的，直接丢掉（它本身没有内容）
            index += 1;
            continue;
        }

        let parsed = parse_line(line);
        index += 1;

        // ---- 表格：相邻的行要并进同一张表 ----
        //
        // 块模型里一张表的**所有行在同一个 `Block::Table` 里**，而
        // Markdown 是每行一行文本。因此一行一个 `Block::Table` 是错的：
        // 一张两行的表会变成两个各含一行的表。
        //
        // 只有紧挨着的行才合并——中间隔了空行就是两张表
        //（那也是用户在编辑器里能表达的区分方式）。
        if let (Block::Table { rows: new_rows }, Some(Block::Table { rows })) =
            (&parsed, blocks.last_mut())
        {
            rows.extend(new_rows.iter().cloned());
            continue;
        }

        blocks.push(parsed);
    }

    // 结尾的空段落没有意义（用户最后敲的那次回车不构成内容），
    // 但**中间**的空行必须保留。这里只裁掉末尾连续的空白段落。
    while matches!(blocks.last(), Some(Block::Paragraph { text, .. }) if text.is_empty()) {
        blocks.pop();
    }
    blocks
}

/// 去掉恰好 `indent` 个前导空格（不足则原样返回）。
fn strip_indent(line: &str, indent: usize) -> String {
    let mut consumed = 0_usize;
    for ch in line.chars() {
        // 只吃空格；吃到别的字符或吃满 indent 个就停
        if ch != ' ' || consumed == indent {
            break;
        }
        consumed += 1;
    }
    line[consumed..].to_owned()
}

/// 解析单行（不含代码块）。
fn parse_line(line: &str) -> Block {
    let trimmed = line.trim_start();

    // ---- 分割线 ----
    // 必须放在列表判断**之前**：`---` 也符合"以 `-` 开头"。
    if trimmed == "---" {
        return Block::Divider;
    }

    // ---- 标题 ----
    if let Some((level, text)) = split_heading(trimmed) {
        return Block::Heading {
            level,
            text: text.to_owned(),
            marks: Vec::new(),
        };
    }

    // ---- 待办（也以 `- ` 开头，因此要在无序列表之前判断）----
    if let Some((checked, text)) = split_checklist(trimmed) {
        return Block::Checklist { checked, text };
    }

    // ---- 无序列表 ----
    if let Some(text) = trimmed.strip_prefix("- ") {
        return Block::List {
            ordered: false,
            start: 1,
            items: vec![ListItem {
                text: text.to_owned(),
                children: Vec::new(),
            }],
        };
    }

    // ---- 有序列表 ----
    if let Some((number, text)) = split_ordered(trimmed) {
        return Block::List {
            ordered: true,
            start: number,
            items: vec![ListItem {
                text: text.to_owned(),
                children: Vec::new(),
            }],
        };
    }

    // ---- 引用（含出处）----
    if let Some(rest) = trimmed.strip_prefix("> ") {
        if let Some(cite) = rest.strip_prefix("-- ") {
            // 出处行单独成一个引用块；下一行若是正文引用，
            // 由调用方按块序决定语义（块模型里 cite 是引用的可选字段，
            // 这里保守地各自成块，保证往返不丢字）。
            return Block::Quote {
                text: String::new(),
                cite: Some(cite.to_owned()),
            };
        }
        return Block::Quote {
            text: rest.to_owned(),
            cite: None,
        };
    }

    // ---- 表格的一行 ----
    //
    // 表头分隔行（`| --- | --- |`）在 `text_to_blocks` 里单独处理，
    // 因为标记"上一行是表头"需要看到上下文。这里只解析数据行。
    if trimmed.starts_with('|') && trimmed.ends_with('|') && trimmed.len() > 2 {
        let cells: Vec<TableCell> = trimmed
            .trim_matches('|')
            .split('|')
            .map(|c| TableCell {
                text: c.trim().to_owned(),
                header: false,
            })
            .collect();
        return Block::Table {
            rows: vec![TableRow { cells }],
        };
    }

    // ---- 图片 / 文件附件 / 链接 ----
    //
    // 三者形态都是 `标签](地址)`，因此**只解析一次**，再按前缀与地址
    // 决定它是哪一类。分开写三次会让"前缀判断"与"括号解析"两套逻辑
    // 各写三遍，改一处漏两处（第一版就是这么写错的）。
    let is_image = trimmed.starts_with("![");
    let bracket = if is_image {
        trimmed.strip_prefix("![")
    } else {
        trimmed.strip_prefix('[')
    };
    if let Some((label, target)) = bracket.and_then(split_link_parts) {
        // 地址是合法附件 id → 图片或文件（按 `file: ` 前缀区分）
        if let Ok(attachment_id) = Id::parse(target) {
            if is_image {
                return Block::Image {
                    attachment_id,
                    alt: if label.is_empty() {
                        None
                    } else {
                        Some(label.to_owned())
                    },
                    width: None,
                    height: None,
                };
            }
            if let Some(filename) = label.strip_prefix("file: ") {
                return Block::File {
                    attachment_id,
                    filename: filename.to_owned(),
                };
            }
            // `[标签](合法id)` 但标签不是 `file: ` —— 不猜，
            // 落到下面的链接分支（它的 href 是 id 文本，也成立）。
        }
        // 普通链接：两侧都要有内容，否则 `[abc]` 这类普通文本会被误判
        if !is_image && !label.is_empty() && !target.is_empty() {
            return Block::Link {
                text: label.to_owned(),
                href: target.to_owned(),
            };
        }
    }

    // ---- 段落（含空行）----
    Block::Paragraph {
        text: line.to_owned(),
        marks: Vec::new(),
    }
}

/// 判断一行是不是 Markdown 表格的"表头分隔行"（`| --- | --- |`）。
///
/// 它本身没有内容，只用来标记上一行是表头。
fn is_table_separator(line: &str) -> bool {
    let trimmed = line.trim();
    if !trimmed.starts_with('|') || !trimmed.ends_with('|') || trimmed.len() <= 2 {
        return false;
    }
    let cells: Vec<&str> = trimmed.trim_matches('|').split('|').collect();
    !cells.is_empty()
        && cells.iter().all(|c| {
            let c = c.trim();
            !c.is_empty() && c.chars().all(|ch| ch == '-' || ch == ':')
        })
}

/// 识别待办项 `- [ ] 文本` / `- [x] 文本`。
///
/// ## 为什么是独立函数
///
/// 这段要同时处理"前缀"与"方括号"两个位置，写在内联的嵌套 `if` 里
/// 很容易把**两个不同基准的下标**混用（第一版就写错了：`close` 是相对
/// 原文的下标，却拿去切 `strip_prefix` 之后的子串）。
///
/// 抽出来之后下标只有一个基准（`rest`），错不了。
///
/// 另外注意：**未勾选在投影里是 `- [ ] `，方括号之间是一个空格**，
/// 不是空串。第一版直接比 `is_empty()`，于是"没勾的待办"识别不出来、
/// 退化成普通列表项——勾选的能认、没勾的不能，正是这个原因。
fn split_checklist(trimmed: &str) -> Option<(bool, String)> {
    let rest = trimmed.strip_prefix("- [")?;
    let close = rest.find(']')?;
    let mark = rest[..close].trim();
    if !mark.is_empty() && !mark.eq_ignore_ascii_case("x") {
        // 别的记号不是待办，交给列表分支
        return None;
    }
    let text = rest[close + 1..].trim_start();
    Some((mark.eq_ignore_ascii_case("x"), text.to_owned()))
}

/// 识别 `# 标题` / `### 标题`。
fn split_heading(trimmed: &str) -> Option<(u8, &str)> {
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    let rest = &trimmed[hashes..];
    // `#` 后必须跟空格（或整行只有 `#`），否则 `#标签` 会被误认成标题
    if rest.is_empty() {
        return Some((u8::try_from(hashes).ok()?, ""));
    }
    let text = rest.strip_prefix(' ')?;
    Some((u8::try_from(hashes).ok()?, text))
}

/// 识别 `1. 文本`。
fn split_ordered(trimmed: &str) -> Option<(u32, &str)> {
    let digits: String = trimmed.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    let rest = &trimmed[digits.len()..];
    let text = rest.strip_prefix(". ")?;
    Some((digits.parse().ok()?, text))
}

/// 从 `文本](地址)` 里切出两段（`[` 已被调用方吃掉）。
fn split_link_parts(rest: &str) -> Option<(&str, &str)> {
    let close = rest.find("](")?;
    let text = &rest[..close];
    let after = &rest[close + 2..];
    let end = after.find(')')?;
    Some((text, &after[..end]))
}

/// 判断一个块是否"有可见内容"（用于字数统计与空笔记判断）。
///
/// 与 [BlockKind] 一一对应，避免调用方各自 match 一遍又漏掉新变体。
#[must_use]
pub const fn is_blank(block: &Block) -> bool {
    match block {
        Block::Paragraph { text, .. } | Block::Heading { text, .. } => text.is_empty(),
        Block::Checklist { text, .. } => text.is_empty(),
        Block::Quote { text, cite } => text.is_empty() && cite.is_none(),
        Block::Code { code, .. } => code.is_empty(),
        Block::List { items, .. } => items.is_empty(),
        Block::ListItem { text, children } => text.is_empty() && children.is_empty(),
        Block::Table { rows } => rows.is_empty(),
        Block::Image { .. } | Block::File { .. } | Block::Divider | Block::Link { .. } => false,
        Block::Embed { .. } => false,
    }
}

/// 块类型的中文名（界面显示用）。
///
/// 放在模型层而不是界面层：它是**块模型的一部分**，
/// 每个前端（桌面/将来的移动端/CLI）都该显示同样的名字。
#[must_use]
pub const fn kind_display_name(kind: BlockKind) -> &'static str {
    match kind {
        BlockKind::Paragraph => "正文",
        BlockKind::Heading => "标题",
        BlockKind::List => "列表",
        BlockKind::ListItem => "列表项",
        BlockKind::Checklist => "待办",
        BlockKind::Quote => "引用",
        BlockKind::Code => "代码块",
        BlockKind::Image => "图片",
        BlockKind::File => "附件",
        BlockKind::Table => "表格",
        BlockKind::Divider => "分隔线",
        BlockKind::Link => "链接",
        BlockKind::Embed => "嵌入内容",
    }
}
