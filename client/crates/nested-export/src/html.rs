// SPDX-License-Identifier: AGPL-3.0-or-later
//! 块文档 → 自包含 HTML。
//!
//! ## 设计
//!
//! - **自包含**：图片以 base64 data URI 内联，单文件即可迁移/分享；
//!   读取字节由调用方通过 `resolve` 回调提供（core 从内容寻址存储读），
//!   本模块不接触 IO；
//! - **转义**：所有用户文本经 [`escape_html`]，先转义再拼标签——
//!   顺序反了就是注入；
//! - 文件附件与 embed 渲染为**占位块**：二进制无法内联为有意义的内容，
//!   占位里写明"需在应用内提取"，不假装它已导出。

use std::fmt::Write as _;

use nested_model::{Block, Document};

type Resolve<'a> = &'a dyn Fn(&nested_model::Id) -> Option<Vec<u8>>;

/// 把文档渲染为自包含 HTML（含 `<!DOCTYPE html>` 与内联样式）。
pub fn document_to_html(document: &Document, resolve: Resolve<'_>) -> String {
    let mut body = String::new();
    for block in &document.blocks {
        render_block(block, resolve, &mut body);
    }
    let mut out = String::new();
    let _ = write!(
        out,
        "<!DOCTYPE html>\n\
         <html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n\
         <title>{}笔记导出{}</title>\n\
         <style>\n\
         body {{ font-family: 'Microsoft YaHei', sans-serif; max-width: 760px; \
         margin: 24px auto; padding: 0 16px; line-height: 1.7; }}\n\
         pre {{ background: #f4f4f4; padding: 10px; border-radius: 6px; \
         overflow-x: auto; }}\n\
         code {{ font-family: Consolas, monospace; }}\n\
         blockquote {{ border-left: 3px solid #bbb; margin: 8px 0; \
         padding: 2px 12px; color: #555; }}\n\
         img {{ max-width: 100%; }}\n\
         table {{ border-collapse: collapse; }}\n\
         td, th {{ border: 1px solid #ccc; padding: 4px 10px; }}\n\
         .attachment {{ color: #777; }}\n\
         .lang {{ color: #999; font-size: 12px; }}\n\
         </style>\n</head>\n<body>\n",
        escape_html("{"),
        escape_html("}")
    );
    out.push_str(&body);
    out.push_str("</body>\n</html>\n");
    out
}

fn render_block(block: &Block, resolve: Resolve<'_>, out: &mut String) {
    match block {
        Block::Paragraph { text, .. } => {
            let _ = writeln!(out, "<p>{}</p>", escape_html(text));
        }
        Block::Heading { level, text, .. } => {
            let level = (*level).clamp(1, 6);
            let _ = writeln!(out, "<h{level}>{}</h{level}>", escape_html(text));
        }
        Block::List {
            ordered,
            start,
            items,
        } => {
            let tag = if *ordered { "ol" } else { "ul" };
            let start_attr = if *ordered && *start != 1 {
                format!(r#" start="{start}""#)
            } else {
                String::new()
            };
            let _ = writeln!(out, "<{tag}{start_attr}>");
            for item in items {
                let _ = writeln!(out, "<li>{}</li>", escape_html(&item.text));
                for child in &item.children {
                    render_block(child, resolve, out);
                }
            }
            let _ = writeln!(out, "</{tag}>");
        }
        Block::ListItem { text, children } => {
            let _ = writeln!(out, "<ul><li>{}</li>", escape_html(text));
            for child in children {
                render_block(child, resolve, out);
            }
            out.push_str("</ul>\n");
        }
        Block::Checklist { checked, text } => {
            let mark = if *checked { "☑" } else { "☐" };
            let style = if *checked {
                " style=\"text-decoration: line-through; color: #888;\""
            } else {
                ""
            };
            let _ = writeln!(
                out,
                "<p class=\"checklist\">{mark} <span{style}>{}</span></p>",
                escape_html(text)
            );
        }
        Block::Quote { text, cite } => {
            let _ = write!(out, "<blockquote><p>{}</p>", escape_html(text));
            if let Some(cite) = cite {
                let _ = writeln!(out, "<p>—— {}</p>", escape_html(cite));
            }
            out.push_str("</blockquote>\n");
        }
        Block::Code { language, code } => {
            if let Some(lang) = language {
                let _ = writeln!(out, "<p class=\"lang\">{}</p>", escape_html(lang));
            }
            let _ = writeln!(out, "<pre><code>{}</code></pre>", escape_html(code));
        }
        Block::Divider => out.push_str("<hr>\n"),
        Block::Image {
            attachment_id, alt, ..
        } => {
            // base64 data URI：单文件自包含，图片随 HTML 一起走
            match resolve(attachment_id) {
                Some(bytes) => {
                    let _ = write!(
                        out,
                        "<p><img src=\"data:application/octet-stream;base64,{}\" \
                         alt=\"{}\"></p>",
                        base64_encode(&bytes),
                        escape_html(alt.as_deref().unwrap_or(""))
                    );
                    out.push('\n');
                }
                None => {
                    let _ = writeln!(
                        out,
                        "<p class=\"attachment\">[图片缺失：{}]</p>",
                        escape_html(alt.as_deref().unwrap_or("（无替代文本）"))
                    );
                }
            }
        }
        Block::File { filename, .. } => {
            let _ = writeln!(
                out,
                "<p class=\"attachment\">📎 附件：{}（二进制内容需在应用内提取）</p>",
                escape_html(filename)
            );
        }
        Block::Table { rows } => {
            out.push_str("<table>\n");
            for row in rows {
                let (tag_open, tag_close) = if row.cells.iter().any(|c| c.header) {
                    ("<th>", "</th>")
                } else {
                    ("<td>", "</td>")
                };
                out.push_str("<tr>");
                for cell in &row.cells {
                    let _ = write!(out, "{tag_open}{}{tag_close}", escape_html(&cell.text));
                }
                out.push_str("</tr>\n");
            }
            out.push_str("</table>\n");
        }
        Block::Link { text, href } => {
            let _ = writeln!(
                out,
                "<p><a href=\"{}\">{}</a></p>",
                escape_html(href),
                escape_html(text)
            );
        }
        Block::Embed {
            provider,
            reference,
        } => {
            let _ = writeln!(
                out,
                "<p class=\"attachment\">[embed: {}/{}]</p>",
                escape_html(provider),
                escape_html(reference)
            );
        }
    }
}

/// HTML 转义（& < > " '）。顺序必须先转 `&`，否则双重转义。
#[must_use]
pub fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// 标准 base64（含 padding）。手写以避免仅为导出引入依赖；
/// 与 RFC 4648 对拍过（见测试）。
#[must_use]
pub fn base64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = u32::from(chunk[0]);
        let b1 = chunk.get(1).map_or(0, |b| u32::from(*b));
        let b2 = chunk.get(2).map_or(0, |b| u32::from(*b));
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(triple >> 18) as usize & 0x3F] as char);
        out.push(ALPHABET[(triple >> 12) as usize & 0x3F] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(triple >> 6) as usize & 0x3F] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[triple as usize & 0x3F] as char
        } else {
            '='
        });
    }
    out
}
