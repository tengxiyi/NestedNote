//! # nested-core —— 拾光笔记内核（Domain Service）
//!
//! Flutter 通过 FFI 只与本 crate 对话（铁律 A1/A3/T4）。
//! 上层看不到 SQL、表结构、文件布局或加密细节。
//!
//! ## 分层
//!
//! ```text
//! Flutter UI  →  FFI（nested-app）  →  nested-core（本 crate，业务 API）
//!                                        ├── nested-model   领域模型（纯数据）
//!                                        ├── nested-db      SQLite / 迁移 / 仓储
//!                                        ├── nested-search  FTS5 全文搜索
//!                                        ├── nested-attachment 附件 CAS
//!                                        ├── nested-import / nested-export
//!                                        ├── nested-sync    同步引擎
//!                                        └── nested-crypto  密钥与加密
//! ```
//!
//! ## 典型用法
//!
//! ```
//! use nested_core::{NestedCore, branding};
//! use nested_model::{Block, Document};
//!
//! let core = NestedCore::open_in_memory()?;
//! let note = core.create_note(None, "第一篇笔记", nested_model::now_ms())?;
//! let mut document = core.get_note_document(&note.id)?;
//! document.blocks.push(Block::paragraph("你好，世界"));
//! let saved = core.save_note(note, document, "device-1", nested_model::now_ms())?;
//!
//! assert_eq!(saved.version, 2);
//! assert_eq!(branding::display_name("zh-CN"), "拾光笔记");
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

#![forbid(unsafe_code)]

pub mod api;
pub mod branding;
pub mod error;

pub use api::{NestedCore, UNKNOWN_DEVICE_ID};
pub use error::{CoreError, CoreResult};

// 重新导出上层必需的模型与查询类型，使 Flutter 只需依赖本 crate。
pub use nested_db::{Database, NoteQuery};
pub use nested_model::{
    Attachment, Block, BlockKind, DOCUMENT_FORMAT_VERSION, Document, Id, InlineMark, ModelError,
    Note, Notebook, Revision, TableCell, TableRow, Tag, Timestamp, now_ms,
};
