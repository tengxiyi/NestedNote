//! # nested-db —— SQLite 存储层
//!
//! 本 crate 是**唯一**允许编写 SQL 的地方（铁律 A7）。上层（`nested-core`）
//! 只调用仓储函数，不接触 SQL、连接或事务对象。
//!
//! ## 铁律映射
//!
//! | 铁律 | 在本 crate 的体现 |
//! |---|---|
//! | D1 原子写 | [`Database::with_transaction`]；`create_with_document` / `save_with_document` 一个事务写完所有表 |
//! | D2 禁止裸 DELETE | 仓储层不提供物理删除函数；软删除用 `deleted_at_ms` |
//! | D6 / Q2 迁移不可变 | [`migrations::MIGRATIONS`] 内置 SQL；改动历史文件会被 `tests/migration_guard.rs` 拦下 |
//! | D12 PRAGMA 基线 | [`db::Database::open`] 统一设置 WAL / foreign_keys / busy_timeout |
//! | Q4 禁止拼接 SQL | 全部使用参数绑定；排序与过滤字段来自白名单结构体 |
//! | R1 禁止 unwrap | 列映射失败一律返回 [`DbError::Corrupt`] |
//!
//! ## 典型用法
//!
//! ```
//! use nested_db::Database;
//! use nested_model::{Block, Document, Note};
//!
//! let db = Database::open_in_memory()?;
//! let note = Note::new(None, "第一篇笔记", nested_model::now_ms())?;
//! let document = Document::from_blocks(vec![Block::paragraph("你好，世界")], nested_model::now_ms());
//!
//! // 写入口需要 &mut Connection：它在内部开启 IMMEDIATE 写事务，
//! // 而 `&mut` 同时让"嵌套事务"在编译期就不可能发生。
//! let mut connection = db.connection()?;
//! nested_db::repositories::notes::create_with_document(&mut connection, &note, &document, "device-1")?;
//! let loaded = nested_db::repositories::notes::get(&connection, &note.id)?;
//! assert!(loaded.is_some());
//!
//! // 只读访问推荐用 with_connection：作用域收敛在一处，
//! // 不会出现"还持有连接又去调 Database 其它方法"的重入错误。
//! drop(connection);
//! let count = db.with_connection(|connection| {
//!     nested_db::repositories::notes::count(connection, false)
//! })?;
//! assert_eq!(count, 1);
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

#![forbid(unsafe_code)]

pub mod db;
pub mod error;
pub mod migrations;
pub mod repositories;
pub mod rowmap;

pub use db::{Database, NoteQuery};
pub use error::{DbError, DbResult};
pub use repositories::notes::is_document_unchanged;
pub use repositories::sync_operations::SyncOperation;
