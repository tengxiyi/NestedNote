//! # server-storage —— 服务端存储
//!
//! PostgreSQL（SQLx）与对象存储。
//!
//! ## 铁律约束
//!
//! - **Q1/Q2**：结构变更只能通过 `server/migrations/` 中的迁移文件，已发布的不可修改；
//! - **S8**：连接池必须有上限，防止一个故障客户端吃掉所有连接；
//! - **S3**：连接串、密码等**禁止**出现在日志中。

#![forbid(unsafe_code)]

pub mod postgres;
pub mod s3;

pub use postgres::Database;

use thiserror::Error;

/// 存储层错误。
#[derive(Debug, Error)]
pub enum StorageError {
    /// 数据库错误（细节只进日志，不返回客户端）。
    #[error("数据库错误：{0}")]
    Database(String),

    /// 迁移失败。
    #[error("迁移失败：{0}")]
    Migration(String),

    /// 对象存储错误。
    #[error("对象存储错误：{0}")]
    ObjectStorage(String),

    /// 资源不存在。
    #[error("资源不存在")]
    NotFound,

    /// 唯一约束冲突。
    #[error("冲突：{0}")]
    Conflict(String),
}

/// 存储结果别名。
pub type StorageResult<T> = std::result::Result<T, StorageError>;
