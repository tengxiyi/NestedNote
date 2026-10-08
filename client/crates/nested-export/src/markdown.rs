// SPDX-License-Identifier: AGPL-3.0-or-later
//! 块文档 → Markdown。
//!
//! ## 与编辑器投影的区别（刻意不同）
//!
//! `nested-model::text_projection` 的文本是**编辑器的输入**：
//! 附件要保留内容寻址 id（往返可逆）。这里的 Markdown 是给**外部工具
//! 与人**看的：id 出了应用毫无意义，因此附件渲染成人类可读的占位
//! （`[附件: 名]`），图片渲染成 `![替代文本]`。
//!
//! ## 行内标记
//!
//! R1/R2-B 阶段界面产生不了行内标记，导出同样忽略（与预览一致）；
//! R2 落地后此处与编辑器投影同步升级。

use nested_model::{Block, Document};

/// 把文档渲染为 Markdown 文本。
#[must_use]
pub fn document_to_markdown(document: &Document) -> String {
    let mut out = String::new();
    for block in &document.blocks {
        render_block(block, &mut out);
    }
    // 文档整体不需要首尾空行修饰：各块渲染自带间隔
    out.trim_end().to_owned()
}

fn render_block(block: &Block, out: &mut String) {
    match block {
        Block::Paragraph { text, .. } => {
            push_line(out, text);
        }
        Block::Heading { level, text, .. } => {
            let hashes = "#".repeat(usize::from((*level).clamp(1, 6)));
            push_line(out, &format!("{hashes} {text}"));
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
                push_line(out, &format!("{marker}{}", item.text));
                // 嵌套子块按两格缩进递归渲染
                for child in &item.children {
                    let mut inner = String::new();
                    render_block(child, &mut inner);
                    for line in inner.lines() {
                        push_line(out, &format!("  {line}"));
                    }
                }
            }
        }
        Block::ListItem { text, children } => {
            push_line(out, &format!("- {text}"));
            for child in children {
                let mut inner = String::new();
                render_block(child, &mut inner);
                for line in inner.lines() {
                    push_line(out, &format!("  {line}"));
                }
            }
        }
        Block::Checklist { checked, text } => {
            push_line(
                out,
                &format!("- [{}] {text}", if *checked { "x" } else { " " }),
            );
        }
        Block::Quote { text, cite } => {
            push_line(out, &format!("> {text}"));
            if let Some(cite) = cite {
                push_line(out, &format!("> —— {cite}"));
            }
        }
        Block::Code { language, code } => {
            push_line(out, &format!("```{}", language.clone().unwrap_or_default()));
            for line in code.split('\n') {
                push_line(out, line);
            }
            push_line(out, "```");
        }
        Block::Divider => push_line(out, "---"),
        // 附件在 Markdown 里是"人类可读的占位"：内容寻址 id 出了应用
        // 没有意义，带上反而让导出文本看起来像坏了
        Block::Image { alt, .. } => {
            push_line(out, &format!("![{}]", alt.clone().unwrap_or_default()));
        }
        Block::File { filename, .. } => {
            push_line(out, &format!("[附件: {filename}]"));
        }
        Block::Table { rows } => {
            for (index, row) in rows.iter().enumerate() {
                let cells: Vec<String> = row.cells.iter().map(|c| c.text.clone()).collect();
                push_line(out, &format!("| {} |", cells.join(" | ")));
                if index == 0 && row.cells.iter().any(|c| c.header) {
                    let bars: Vec<&str> = row.cells.iter().map(|_| "---").collect();
                    push_line(out, &format!("| {} |", bars.join(" | ")));
                }
            }
        }
        Block::Link { text, href } => push_line(out, &format!("[{text}]({href})")),
        Block::Embed {
            provider,
            reference,
        } => push_line(out, &format!("[embed: {provider}/{reference}]")),
    }
    out.push('\n');
}

fn push_line(out: &mut String, line: &str) {
    out.push_str(line);
    out.push('\n');
}
