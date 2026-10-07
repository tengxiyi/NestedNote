//! # nested-model —— 领域模型
//!
//! 本 crate 只有**数据结构与纯函数**：不碰数据库、不碰文件、不碰网络。
//! 它定义了整个应用的事实形状（技术文档 §6 Document Model）。
//!
//! ## 铁律约束
//!
//! - **禁止**在核心持久化格式中使用 HTML / Markdown（铁律 T5）。它们只是投影。
//! - ID **必须**是 UUIDv7（时间有序、全局唯一，铁律 D7）。
//! - 时间 **必须**是 UTC 毫秒整数（铁律 D8）。
//! - 删除 **必须**走软删除字段（铁律 T7 / D2）。

#![forbid(unsafe_code)]

mod block;
mod diff;
mod document;
mod entity;
mod error;
mod id;
mod time;

pub use block::{Block, BlockKind, InlineMark, ListItem, TableCell, TableRow};
pub use diff::{
    DiffKind, DiffLine, DiffOutcome, DiffSide, DocumentDiff, diff_documents, diff_lines,
    flatten_lines,
};
pub use document::{DOCUMENT_FORMAT_VERSION, Document, DocumentMetadata};
pub use entity::{
    Attachment, MAX_FILENAME_CHARS, MAX_NOTEBOOK_NAME_CHARS, MAX_SUMMARY_CHARS, MAX_TAG_NAME_CHARS,
    MAX_TITLE_CHARS, Note, Notebook, Revision, Tag,
};
pub use error::{ModelError, Result};
pub use id::Id;
pub use time::{Timestamp, now_ms};
