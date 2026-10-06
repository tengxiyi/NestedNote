//! 文档（Document）：一个笔记的完整结构化内容。
//!
//! 存储表示是 JSON 字节（`documents.content` BLOB），格式由
//! [`DocumentMetadata::format`] 标识、由 [`DOCUMENT_FORMAT_VERSION`] 定版。
//!
//! ## 版本演进规则（铁律 A10 / D6）
//!
//! - 新增块类型或**可选**字段：**不**升版本，旧程序读新文档时未知字段被忽略。
//! - 删除字段、改变字段含义、改变必需性：**必须**升版本，并**必须**提供迁移函数。
//! - 反序列化遇到高于本程序支持的版本时**必须**报错，禁止"尽力解析"造成静默数据损坏。

use serde::{Deserialize, Serialize};

use crate::{Block, ModelError, Result};

/// 当前程序支持的文档格式版本。
pub const DOCUMENT_FORMAT_VERSION: u32 = 1;

/// 文档元信息。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentMetadata {
    /// 格式标识，固定为 `"nested.blocks"`（便于未来引入其他格式并存）。
    pub format: String,
    /// 格式版本。
    pub version: u32,
    /// 创建时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 最近修改时间（UTC 毫秒）。
    pub updated_at_ms: i64,
}

impl DocumentMetadata {
    /// 以当前版本构造元信息。
    #[must_use]
    pub fn new(created_at_ms: i64, updated_at_ms: i64) -> Self {
        Self {
            format: Self::FORMAT.to_owned(),
            version: DOCUMENT_FORMAT_VERSION,
            created_at_ms,
            updated_at_ms,
        }
    }

    /// 格式标识常量。
    pub const FORMAT: &'static str = "nested.blocks";
}

/// 一篇笔记的结构化内容。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    /// 元信息（含格式与版本）。
    pub metadata: DocumentMetadata,
    /// 块列表。
    #[serde(default)]
    pub blocks: Vec<Block>,
}

impl Document {
    /// 创建空文档。
    #[must_use]
    pub fn empty(at_ms: i64) -> Self {
        Self {
            metadata: DocumentMetadata::new(at_ms, at_ms),
            blocks: Vec::new(),
        }
    }

    /// 从块列表创建文档。
    #[must_use]
    pub fn from_blocks(blocks: Vec<Block>, at_ms: i64) -> Self {
        Self {
            metadata: DocumentMetadata::new(at_ms, at_ms),
            blocks,
        }
    }

    /// 序列化为存储字节（JSON）。
    ///
    /// # Errors
    ///
    /// 序列化失败时返回 [`ModelError::Validation`]。
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).map_err(|_| ModelError::Validation {
            field: "document",
            reason: "文档无法序列化为 JSON",
        })
    }

    /// 从存储字节反序列化。
    ///
    /// # Errors
    ///
    /// - 字节不是合法 JSON 或结构不匹配 → [`ModelError::Validation`]
    /// - 文档版本高于本程序支持 → [`ModelError::UnsupportedDocumentVersion`]
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let document: Self = serde_json::from_slice(bytes).map_err(|_| ModelError::Validation {
            field: "document",
            reason: "文档字节不是合法的块模型 JSON",
        })?;
        if document.metadata.version > DOCUMENT_FORMAT_VERSION {
            return Err(ModelError::UnsupportedDocumentVersion {
                found: document.metadata.version,
                supported: DOCUMENT_FORMAT_VERSION,
            });
        }
        Ok(document)
    }

    /// 所有块（含嵌套子块）的可搜索文本，按出现顺序拼接。
    #[must_use]
    pub fn searchable_text(&self) -> String {
        let mut parts = Vec::new();
        for block in &self.blocks {
            collect_text(block, &mut parts);
        }
        parts.join(" ")
    }

    /// 块数量（含嵌套）。
    #[must_use]
    pub fn block_count(&self) -> usize {
        self.blocks.iter().map(count_blocks).sum()
    }

    /// 文档中引用的全部附件标识（去重后按首次出现顺序）。
    #[must_use]
    pub fn attachment_ids(&self) -> Vec<crate::Id> {
        let mut ids = Vec::new();
        for block in &self.blocks {
            collect_attachment_ids(block, &mut ids);
        }
        ids
    }

    /// 更新修改时间。
    pub fn touch(&mut self, at_ms: i64) {
        self.metadata.updated_at_ms = at_ms;
    }
}

/// 递归收集块及其子块的文本。
///
/// ## 关于列表的重复收集（已修复的缺陷）
///
/// [`Block::searchable_text`] 对 `List` 变体**已经把各项文本拼进返回值**，
/// 因此这里不能再逐项 `push`——否则同一条列表文案会在全文索引里出现两次
/// （FTS5 会把重复文本算进词频，直接影响相关度排序）。
/// 正确做法是：列表的"容器文本"直接采用 `searchable_text()`，
/// 递归只负责处理**嵌套子块**。
fn collect_text(block: &Block, out: &mut Vec<String>) {
    let text = block.searchable_text();
    if !text.is_empty() {
        out.push(text);
    }
    match block {
        Block::List { items, .. } => {
            for item in items {
                for child in &item.children {
                    collect_text(child, out);
                }
            }
        }
        Block::ListItem { children, .. } => {
            for child in children {
                collect_text(child, out);
            }
        }
        _ => {}
    }
}

/// 递归统计块数量。
///
/// 计数规则：列表容器本身算 1 块，**每个列表项也算 1 块**（列表项是可独立编辑的
/// 内容单元），再加上各项的嵌套子块。
fn count_blocks(block: &Block) -> usize {
    match block {
        Block::List { items, .. } => {
            1 + items
                .iter()
                .map(|item| 1 + item.children.iter().map(count_blocks).sum::<usize>())
                .sum::<usize>()
        }
        Block::ListItem { children, .. } => 1 + children.iter().map(count_blocks).sum::<usize>(),
        _ => 1,
    }
}

/// 递归收集附件标识。
fn collect_attachment_ids(block: &Block, out: &mut Vec<crate::Id>) {
    let push = |id: crate::Id, out: &mut Vec<crate::Id>| {
        if !out.contains(&id) {
            out.push(id);
        }
    };
    if let Some(id) = block.attachment_id() {
        push(id, out);
    }
    match block {
        Block::List { items, .. } => {
            for item in items {
                for child in &item.children {
                    collect_attachment_ids(child, out);
                }
            }
        }
        Block::ListItem { children, .. } => {
            for child in children {
                collect_attachment_ids(child, out);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Id, TableCell, TableRow};

    fn sample_document() -> Document {
        Document::from_blocks(
            vec![
                Block::heading(1, "项目计划").expect("level ok"),
                Block::paragraph("这是第一段内容。"),
                Block::checklist("完成数据库设计", false),
                Block::List {
                    ordered: false,
                    start: 1,
                    items: vec![
                        crate::ListItem {
                            text: "第一项".to_owned(),
                            children: Vec::new(),
                        },
                        crate::ListItem {
                            text: "第二项".to_owned(),
                            children: Vec::new(),
                        },
                    ],
                },
            ],
            1_700_000_000_000,
        )
    }

    #[test]
    fn document_roundtrips_through_bytes() {
        let document = sample_document();
        let bytes = document.to_bytes().expect("serialize");
        let back = Document::from_bytes(&bytes).expect("deserialize");
        assert_eq!(back, document);
    }

    #[test]
    fn new_document_uses_current_version() {
        let document = Document::empty(0);
        assert_eq!(document.metadata.version, DOCUMENT_FORMAT_VERSION);
        assert_eq!(document.metadata.format, DocumentMetadata::FORMAT);
    }

    #[test]
    fn future_version_is_rejected_not_silently_parsed() {
        let mut document = sample_document();
        document.metadata.version = DOCUMENT_FORMAT_VERSION + 1;
        let bytes = serde_json::to_vec(&document).expect("serialize");
        let err = Document::from_bytes(&bytes).expect_err("must reject future version");
        assert!(matches!(err, ModelError::UnsupportedDocumentVersion { .. }));
    }

    #[test]
    fn garbage_bytes_are_rejected() {
        assert!(Document::from_bytes(b"not json at all").is_err());
    }

    #[test]
    fn searchable_text_includes_nested_and_table_content() {
        let document = Document::from_blocks(
            vec![
                Block::paragraph("hello"),
                Block::Table {
                    rows: vec![TableRow {
                        cells: vec![TableCell::new("单元格")],
                    }],
                },
            ],
            0,
        );
        let text = document.searchable_text();
        assert!(text.contains("hello"));
        assert!(text.contains("单元格"));
    }

    #[test]
    fn searchable_text_collects_list_item_text_exactly_once() {
        // 回归测试：曾经 searchable_text() 与 collect_text() 都会拼列表项文本，
        // 导致同一条文案在全文索引里出现两次（影响 FTS5 词频与相关度）。
        let document = Document::from_blocks(
            vec![Block::List {
                ordered: false,
                start: 1,
                items: vec![crate::ListItem {
                    text: "独一无二的条目".to_owned(),
                    children: Vec::new(),
                }],
            }],
            0,
        );

        let text = document.searchable_text();
        assert_eq!(
            text.matches("独一无二的条目").count(),
            1,
            "列表项文本必须只出现一次，实际得到：{text}"
        );
    }

    #[test]
    fn searchable_text_includes_nested_children_of_list_items() {
        let document = Document::from_blocks(
            vec![Block::List {
                ordered: false,
                start: 1,
                items: vec![crate::ListItem {
                    text: "父项".to_owned(),
                    children: vec![Block::paragraph("子块内容")],
                }],
            }],
            0,
        );

        let text = document.searchable_text();
        assert!(text.contains("父项"));
        assert!(text.contains("子块内容"), "嵌套子块也必须进入索引：{text}");
        assert_eq!(text.matches("父项").count(), 1);
    }

    #[test]
    fn searchable_text_includes_nested_list_item_block_children() {
        // `Block::ListItem` 变体（与 List 内部的 ListItem 结构体是两回事）
        let document = Document::from_blocks(
            vec![Block::ListItem {
                text: "顶层项".to_owned(),
                children: vec![Block::paragraph("它的子块")],
            }],
            0,
        );

        let text = document.searchable_text();
        assert!(text.contains("顶层项"));
        assert!(text.contains("它的子块"));
    }

    #[test]
    fn block_count_includes_children_and_list_items() {
        let document = Document::from_blocks(
            vec![Block::List {
                ordered: false,
                start: 1,
                items: vec![crate::ListItem {
                    text: "父项".to_owned(),
                    children: vec![Block::paragraph("子块")],
                }],
            }],
            0,
        );
        assert_eq!(document.block_count(), 3);
    }

    #[test]
    fn attachment_ids_are_collected_and_deduplicated() {
        let id = Id::new();
        let document = Document::from_blocks(
            vec![
                Block::Image {
                    attachment_id: id,
                    alt: None,
                    width: None,
                    height: None,
                },
                Block::File {
                    attachment_id: id,
                    filename: "a.pdf".to_owned(),
                },
            ],
            0,
        );
        assert_eq!(document.attachment_ids(), vec![id]);
    }

    #[test]
    fn touch_updates_only_updated_at() {
        let mut document = Document::empty(100);
        document.touch(200);
        assert_eq!(document.metadata.created_at_ms, 100);
        assert_eq!(document.metadata.updated_at_ms, 200);
    }
}
