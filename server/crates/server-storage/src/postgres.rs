//! PostgreSQL 连接池与迁移。

use sqlx::postgres::{PgPool, PgPoolOptions};
use std::time::Duration;

use crate::{StorageError, StorageResult};

/// 连接池默认最大连接数（铁律 S8：必须有上限）。
pub const DEFAULT_MAX_CONNECTIONS: u32 = 10;

/// 获取连接的超时时间。
pub const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(5);

/// 数据库句柄。
#[derive(Debug, Clone)]
pub struct Database {
    pool: PgPool,
}

impl Database {
    /// 建立连接池。
    ///
    /// **不会**在此时执行迁移 —— 迁移是显式动作，避免"启动即改结构"的意外（铁律 Q1）。
    ///
    /// # Errors
    ///
    /// 连接串非法或连接失败时返回 [`StorageError::Database`]。
    pub async fn connect(database_url: &str) -> StorageResult<Self> {
        let pool = PgPoolOptions::new()
            .max_connections(DEFAULT_MAX_CONNECTIONS)
            .acquire_timeout(ACQUIRE_TIMEOUT)
            .connect(database_url)
            .await
            .map_err(|error| StorageError::Database(describe(&error)))?;
        Ok(Self { pool })
    }

    /// 底层连接池。
    #[must_use]
    pub const fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// 执行编译期内嵌的迁移。
    ///
    /// 迁移文件位于 `server/migrations/`；**已发布的迁移文件禁止修改**（铁律 Q2），
    /// 修正必须新增文件。
    ///
    /// # Errors
    ///
    /// 迁移执行失败时返回 [`StorageError::Migration`]。
    pub async fn migrate(&self) -> StorageResult<()> {
        sqlx::migrate!("../../migrations")
            .run(&self.pool)
            .await
            .map_err(|error| StorageError::Migration(error.to_string()))
    }

    /// 健康检查：`SELECT 1`。
    ///
    /// # Errors
    ///
    /// 连接不可用时返回 [`StorageError::Database`]。
    pub async fn ping(&self) -> StorageResult<()> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map(|_| ())
            .map_err(|error| StorageError::Database(describe(&error)))
    }
}

/// 把 sqlx 错误压成**不含连接串**的描述（铁律 S3：日志与错误不得泄露凭据）。
///
/// 刻意不直接 `to_string()` 整个错误：`sqlx::Error` 的某些变体（配置错误、
/// 迁移错误）会把连接串或文件路径带进消息里。
fn describe(error: &sqlx::Error) -> String {
    match error {
        sqlx::Error::Database(inner) => format!("database error: {}", inner.message()),
        sqlx::Error::PoolTimedOut => "connection pool timed out".to_owned(),
        sqlx::Error::PoolClosed => "connection pool closed".to_owned(),
        sqlx::Error::RowNotFound => "row not found".to_owned(),
        sqlx::Error::ColumnNotFound(name) => format!("column not found: {name}"),
        sqlx::Error::ColumnIndexOutOfBounds { index, len } => {
            format!("column index out of bounds: {index} >= {len}")
        }
        sqlx::Error::Decode(_) => "decode error".to_owned(),
        sqlx::Error::Encode(_) => "encode error".to_owned(),
        sqlx::Error::Migrate(_) => "migration error".to_owned(),
        sqlx::Error::Configuration(_) => "configuration error".to_owned(),
        sqlx::Error::Io(inner) => format!("io error: {}", inner.kind()),
        // 兜底：不打印原文，避免任何未知变体携带凭据或路径
        _ => "sqlx error".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pool_defaults_are_bounded() {
        // 铁律 S8：连接数必须有硬上限，不能是"无限"。
        // 通过变量中转，让断言在运行期求值（常量断言会被 clippy 判定为无意义）。
        let max_connections = DEFAULT_MAX_CONNECTIONS;
        let acquire_timeout_secs = ACQUIRE_TIMEOUT.as_secs();
        assert!(max_connections > 0, "连接池上限必须大于 0");
        assert!(max_connections <= 100, "连接池上限不应超过 100");
        assert!(acquire_timeout_secs > 0, "获取连接必须有超时");
    }

    #[test]
    fn error_description_never_contains_credentials() {
        // 构造一个不含真实凭据的替代错误，验证描述函数不会回显连接串
        let error = sqlx::Error::PoolTimedOut;
        let text = describe(&error);
        assert!(!text.contains("postgres://"));
        assert!(!text.contains("password"));
    }
}
