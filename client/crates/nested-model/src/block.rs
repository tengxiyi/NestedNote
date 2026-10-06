//! 块模型（Block Model）。
//!
//! 这是本项目的**核心持久化格式**（铁律 T5：禁止用 HTML/Markdown 当核心格式）。
//! HTML / Markdown / 纯文本都只是本模型的**投影（renderer）**。
//!
//! serde 表示为 `{"type": "...", ...}`，与《技术文档》§6 的示例一致：
//!
//! ```json
//! { "type": "heading", "level": 1, "text": "项目计划" }
//! ```

use serde::{Deserialize, Serialize};

use crate::Id;

/// 块类型判别值。仅用于过滤、统计与 UI 图标映射，不参与序列化。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockKind {
    /// 段落。
    Paragraph,
    /// 标题。
    Heading,
    /// 列表（有序/无序）。
    List,
    /// 列表项（嵌套在 [`Block::List`] 内）。
    ListItem,
    /// 待办项。
    Checklist,
    /// 引用。
    Quote,
    /// 代码块。
    Code,
    /// 图片。
    Image,
    /// 文件附件。
    File,
    /// 表格。
    Table,
    /// 分割线。
    Divider,
    /// 链接（独立成块的链接卡片）。
    Link,
    /// 嵌入内容占位（P7 能力预留）。
    Embed,
}

/// 行内标记：描述一段文本的样式，而不是把样式写进文本里。
///
/// 采用 UTF-8 **字节偏移**（`[start, end)`）以便零拷贝切片。
/// 解析器必须保证偏移落在字符边界上（铁律 U3：禁止按 UTF-16 code unit 切割）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InlineMark {
    /// 起始字节偏移（含）。
    pub start: usize,
    /// 结束字节偏移（不含）。
    pub end: usize,
    /// 标记种类。
    pub kind: InlineMarkKind,
}

/// 行内标记种类。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum InlineMarkKind {
    /// 加粗。
    Bold,
    /// 斜体。
    Italic,
    /// 删除线。
    Strike,
    /// 行内代码。
    Code,
    /// 链接。
    Link {
        /// 目标地址。
        href: String,
    },
}

/// 表格单元。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableCell {
    /// 单元格文本。
    pub text: String,
    /// 是否表头单元。
    #[serde(default, skip_serializing_if = "is_false")]
    pub header: bool,
}

impl TableCell {
    /// 构造一个普通单元。
    #[must_use]
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            header: false,
        }
    }
}

/// 表格行。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableRow {
    /// 该行的单元。
    #[serde(default)]
    pub cells: Vec<TableCell>,
}

/// 文档中的一个块。
///
/// 新增块类型时**只能新增变体**，禁止改变已有变体的语义或字段含义（铁律 A10）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum Block {
    /// 段落。
    Paragraph {
        /// 文本内容。
        #[serde(default)]
        text: String,
        /// 行内标记。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        marks: Vec<InlineMark>,
    },
    /// 标题。
    Heading {
        /// 层级，1–6。
        level: u8,
        /// 文本内容。
        #[serde(default)]
        text: String,
        /// 行内标记。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        marks: Vec<InlineMark>,
    },
    /// 列表容器。
    List {
        /// 是否有序。
        #[serde(default)]
        ordered: bool,
        /// 起始序号（有序列表有效）。
        #[serde(
            default = "default_list_start",
            skip_serializing_if = "is_default_list_start"
        )]
        start: u32,
        /// 列表项。
        #[serde(default)]
        items: Vec<ListItem>,
    },
    /// 列表项。
    ListItem {
        /// 文本内容。
        #[serde(default)]
        text: String,
        /// 嵌套的子块。
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        children: Vec<Block>,
    },
    /// 待办项。
    Checklist {
        /// 是否已完成。
        #[serde(default)]
        checked: bool,
        /// 文本内容。
        #[serde(default)]
        text: String,
    },
    /// 引用。
    Quote {
        /// 文本内容。
        #[serde(default)]
        text: String,
        /// 引用来源（可选）。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cite: Option<String>,
    },
    /// 代码块。
    Code {
        /// 语言标识（可选）。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        language: Option<String>,
        /// 代码正文。
        #[serde(default)]
        code: String,
    },
    /// 图片。
    Image {
        /// 附件标识（内容寻址存储中的记录）。
        attachment_id: Id,
        /// 替代文本。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        alt: Option<String>,
        /// 原始宽度（像素，可选）。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        width: Option<u32>,
        /// 原始高度（像素，可选）。
        #[serde(default, skip_serializing_if = "Option::is_none")]
        height: Option<u32>,
    },
    /// 文件附件。
    File {
        /// 附件标识。
        attachment_id: Id,
        /// 展示用文件名。
        filename: String,
    },
    /// 表格。
    Table {
        /// 表格行。
        #[serde(default)]
        rows: Vec<TableRow>,
    },
    /// 分割线。
    Divider,
    /// 链接。
    Link {
        /// 展示文本。
        text: String,
        /// 目标地址。
        href: String,
    },
    /// 嵌入内容占位（P7）。
    Embed {
        /// 提供方标识，如 `"youtube"`。
        provider: String,
        /// 提供方侧的资源标识。
        reference: String,
    },
}

/// 列表项的简化表示（用于 [`Block::List`]）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListItem {
    /// 文本内容。
    #[serde(default)]
    pub text: String,
    /// 嵌套的子块。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Block>,
}

/// 有序列表默认起始序号。
const fn default_list_start() -> u32 {
    1
}

/// 判断起始序号是否为默认值（用于序列化省略）。
const fn is_default_list_start(start: &u32) -> bool {
    *start == default_list_start()
}

/// serde 辅助：`false` 时省略字段。
const fn is_false(value: &bool) -> bool {
    !*value
}

impl Block {
    /// 构造段落块。
    #[must_use]
    pub fn paragraph(text: impl Into<String>) -> Self {
        Self::Paragraph {
            text: text.into(),
            marks: Vec::new(),
        }
    }

    /// 构造标题块。
    ///
    /// # Errors
    ///
    /// `level` 不在 1–6 时返回 [`crate::ModelError::Validation`]。
    pub fn heading(level: u8, text: impl Into<String>) -> crate::Result<Self> {
        if !(1..=6).contains(&level) {
            return Err(crate::ModelError::Validation {
                field: "heading.level",
                reason: "标题层级必须在 1–6 之间",
            });
        }
        Ok(Self::Heading {
            level,
            text: text.into(),
            marks: Vec::new(),
        })
    }

    /// 构造待办块。
    #[must_use]
    pub fn checklist(text: impl Into<String>, checked: bool) -> Self {
        Self::Checklist {
            checked,
            text: text.into(),
        }
    }

    /// 构造代码块。
    #[must_use]
    pub fn code(language: Option<impl Into<String>>, code: impl Into<String>) -> Self {
        Self::Code {
            language: language.map(Into::into),
            code: code.into(),
        }
    }

    /// 块类型判别值。
    #[must_use]
    pub const fn kind(&self) -> BlockKind {
        match self {
            Self::Paragraph { .. } => BlockKind::Paragraph,
            Self::Heading { .. } => BlockKind::Heading,
            Self::List { .. } => BlockKind::List,
            Self::ListItem { .. } => BlockKind::ListItem,
            Self::Checklist { .. } => BlockKind::Checklist,
            Self::Quote { .. } => BlockKind::Quote,
            Self::Code { .. } => BlockKind::Code,
            Self::Image { .. } => BlockKind::Image,
            Self::File { .. } => BlockKind::File,
            Self::Table { .. } => BlockKind::Table,
            Self::Divider => BlockKind::Divider,
            Self::Link { .. } => BlockKind::Link,
            Self::Embed { .. } => BlockKind::Embed,
        }
    }

    /// 进入全文搜索索引的纯文本（图片/文件/分割线等无文本块返回空串）。
    ///
    /// **注意**：附件正文本身**不**入索引（那是 OCR 的职责，P7）；
    /// 这里只索引用户可见的文字。
    #[must_use]
    pub fn searchable_text(&self) -> String {
        match self {
            Self::Paragraph { text, .. } | Self::Heading { text, .. } => text.clone(),
            Self::List { items, .. } => {
                let mut out = String::new();
                for item in items {
                    out.push_str(&item.text);
                    out.push(' ');
                }
                out.trim_end().to_owned()
            }
            Self::ListItem { text, .. } | Self::Checklist { text, .. } => text.clone(),
            Self::Quote { text, .. } => text.clone(),
            Self::Code { code, .. } => code.clone(),
            Self::Link { text, href } => format!("{text} {href}"),
            Self::Table { rows } => {
                let mut cells = Vec::new();
                for row in rows {
                    for cell in &row.cells {
                        cells.push(cell.text.as_str());
                    }
                }
                cells.join(" ")
            }
            Self::Image { .. } | Self::File { .. } | Self::Divider | Self::Embed { .. } => {
                String::new()
            }
        }
    }

    /// 引用的附件标识（无附件则 `None`）。
    #[must_use]
    pub const fn attachment_id(&self) -> Option<Id> {
        match self {
            Self::Image { attachment_id, .. } | Self::File { attachment_id, .. } => {
                Some(*attachment_id)
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heading_serializes_in_documented_shape() {
        let block = Block::heading(1, "项目计划").expect("valid level");
        let json = serde_json::to_value(&block).expect("serialize");
        assert_eq!(json["type"], "heading");
        assert_eq!(json["level"], 1);
        assert_eq!(json["text"], "项目计划");
    }

    #[test]
    fn heading_level_out_of_range_is_rejected() {
        assert!(Block::heading(0, "x").is_err());
        assert!(Block::heading(7, "x").is_err());
    }

    #[test]
    fn unknown_block_type_is_rejected() {
        let bad = r#"{"type":"holo_projection","text":"hi"}"#;
        assert!(serde_json::from_str::<Block>(bad).is_err());
    }

    #[test]
    fn checklist_roundtrips() {
        let block = Block::checklist("完成数据库设计", false);
        let json = serde_json::to_string(&block).expect("serialize");
        assert_eq!(
            json,
            r#"{"type":"checklist","checked":false,"text":"完成数据库设计"}"#
        );
        let back: Block = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, block);
    }

    #[test]
    fn searchable_text_collects_visible_text_only() {
        assert_eq!(Block::paragraph("你好").searchable_text(), "你好");
        assert_eq!(Block::Divider.searchable_text(), "");
        let img = Block::Image {
            attachment_id: Id::new(),
            alt: None,
            width: None,
            height: None,
        };
        assert_eq!(img.searchable_text(), "");
        assert!(img.attachment_id().is_some());
    }

    #[test]
    fn list_start_default_is_omitted_from_json() {
        let list = Block::List {
            ordered: true,
            start: 1,
            items: Vec::new(),
        };
        let json = serde_json::to_string(&list).expect("serialize");
        assert!(!json.contains("start"), "默认 start 应被省略：{json}");
    }

    #[test]
    fn lists_and_chinese_text_block_kinds() {
        assert_eq!(Block::paragraph("a").kind(), BlockKind::Paragraph);
        assert_eq!(
            Block::code(Some("rust"), "fn main() {}").kind(),
            BlockKind::Code
        );
    }
}
