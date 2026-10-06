//! 数据库句柄：打开、PRAGMA 基线、事务、完整性校验。
//!
//! ## 连接模型（当前阶段）
//!
//! 单写入连接 + 互斥锁。理由：
//! - SQLite 在 WAL 模式下同一时刻**只允许一个写者**，多写连接只会互相 `SQLITE_BUSY`；
//! - 第一阶段（P1/P2）的瓶颈在索引与查询设计，不在连接数；
//! - 引入连接池属于性能优化，必须在 P4 有基准数据支撑后再做（铁律 P2：先测量再优化）。
//!
//! 多读者优化留给 P4，届时通过 `criterion` 基准证明必要性。

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior};

use crate::DbError;
use crate::migrations;

/// SQLite 建议的最小 WAL 自动检查点阈值。
const WAL_AUTOCHECKPOINT_PAGES: i64 = 1000;

/// 忙等待超时（毫秒）：让并发写者等待而不是立刻失败。
const BUSY_TIMEOUT_MS: u64 = 5000;

/// 分页大小的硬上限：防止 UI 误传巨大 `limit` 把整库读进内存（铁律 P 组）。
pub const MAX_PAGE_SIZE: u32 = 500;

/// 笔记列表查询条件。
///
/// 字段全部是**结构化枚举**而非 SQL 片段，从设计上杜绝拼接注入（铁律 Q4）。
#[derive(Debug, Clone, Copy, Default)]
pub struct NoteQuery<'a> {
    /// 限定笔记本。
    pub notebook_id: Option<&'a nested_model::Id>,
    /// 是否包含回收站中的笔记（默认不包含）。
    pub include_deleted: bool,
    /// 仅返回已归档（`Some(true)`）或未归档（`Some(false)`）；`None` 表示不限。
    pub archived: Option<bool>,
    /// 分页偏移。
    pub offset: u32,
    /// 分页大小；`0` 视为默认 50，且**永远**不会超过 [`MAX_PAGE_SIZE`]。
    pub limit: u32,
}

impl NoteQuery<'_> {
    /// 规范化后的分页大小。
    #[must_use]
    pub fn effective_limit(&self) -> u32 {
        if self.limit == 0 {
            50
        } else {
            self.limit.min(MAX_PAGE_SIZE)
        }
    }
}

/// 数据库句柄。
#[derive(Debug)]
pub struct Database {
    /// 连接持有者。`None` 仅出现在"已关闭"状态，用于显式释放。
    connection: Option<Mutex<Connection>>,
    /// 数据库文件路径（内存库为 `None`）。
    path: Option<PathBuf>,
}

impl Database {
    /// 打开（或创建）位于 `path` 的数据库，并执行迁移。
    ///
    /// # Errors
    ///
    /// - 文件无法打开 → [`DbError::Sqlite`]
    /// - 迁移失败 → [`DbError::Migrate`]（事务回滚，原库不受损）
    /// - 库版本高于程序 → [`DbError::SchemaTooNew`]
    pub fn open(path: impl AsRef<Path>) -> Result<Self, DbError> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)
                .map_err(|_| DbError::Sqlite(rusqlite::Error::InvalidPath(parent.to_path_buf())))?;
        }
        let connection = Connection::open_with_flags(&path, open_flags())?;
        Self::from_connection(connection, Some(path))
    }

    /// 打开一个内存数据库（用于测试与 CLI 快速验证）。
    ///
    /// # Errors
    ///
    /// 迁移失败时返回 [`DbError::Migrate`]。
    pub fn open_in_memory() -> Result<Self, DbError> {
        let connection = Connection::open_in_memory()?;
        Self::from_connection(connection, None)
    }

    /// 应用 PRAGMA 基线并执行迁移。
    fn from_connection(mut connection: Connection, path: Option<PathBuf>) -> Result<Self, DbError> {
        configure_pragmas(&connection)?;
        migrations::apply(&mut connection)?;
        Ok(Self {
            connection: Some(Mutex::new(connection)),
            path,
        })
    }

    /// 数据库文件路径（内存库返回 `None`）。
    #[must_use]
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// 当前 schema 版本。
    ///
    /// # Errors
    ///
    /// 连接已关闭或 PRAGMA 读取失败时返回错误。
    pub fn schema_version(&self) -> Result<u32, DbError> {
        let guard = self.connection()?;
        migrations::current_version(&guard)
    }

    /// 借用底层连接（只读用途）。
    ///
    /// # Errors
    ///
    /// 连接已关闭时返回 [`DbError::Sqlite`]。
    pub fn connection(&self) -> Result<MutexGuard<'_, Connection>, DbError> {
        match self.connection.as_ref() {
            Some(mutex) => mutex
                .lock()
                .map_err(|_| DbError::Sqlite(rusqlite::Error::InvalidQuery)),
            None => Err(DbError::Sqlite(rusqlite::Error::InvalidQuery)),
        }
    }

    /// 在**单个事务**中执行一段操作（铁律 D1：一次业务操作 = 一个事务）。
    ///
    /// 闭包返回 `Err` 时事务自动回滚。
    ///
    /// # Errors
    ///
    /// 连接不可用、事务开启或提交失败时返回错误。
    pub fn with_transaction<T, F>(&self, f: F) -> Result<T, DbError>
    where
        F: FnOnce(&Transaction<'_>) -> Result<T, DbError>,
    {
        let mut guard = self.connection()?;
        let transaction = guard.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let value = f(&transaction)?;
        transaction.commit()?;
        Ok(value)
    }

    /// 执行 `PRAGMA integrity_check`。
    ///
    /// # Errors
    ///
    /// 返回非 `ok` 结果时返回 [`DbError::IntegrityCheckFailed`]。
    pub fn check_integrity(&self) -> Result<(), DbError> {
        let guard = self.connection()?;
        let result: String = guard.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
        if result.eq_ignore_ascii_case("ok") {
            Ok(())
        } else {
            Err(DbError::IntegrityCheckFailed { detail: result })
        }
    }

    /// 轻量健康检查：能执行一次查询即视为可用。
    ///
    /// # Errors
    ///
    /// 连接不可用时返回错误。
    pub fn ping(&self) -> Result<(), DbError> {
        let guard = self.connection()?;
        let _: i64 = guard.query_row("SELECT 1", [], |row| row.get(0))?;
        Ok(())
    }

    /// 读取一条设置项。
    ///
    /// # Errors
    ///
    /// 查询失败时返回 [`DbError::Sqlite`]。
    pub fn setting(&self, key: &str) -> Result<Option<String>, DbError> {
        let guard = self.connection()?;
        let mut statement = guard.prepare_cached("SELECT value FROM settings WHERE key = ?1")?;
        let mut rows = statement.query([key])?;
        match rows.next()? {
            Some(row) => Ok(Some(row.get(0)?)),
            None => Ok(None),
        }
    }

    /// 写入一条设置项（存在则覆盖）。
    ///
    /// **禁止**用本方法存放密钥/token（铁律 D11：密钥必须进平台安全存储）。
    ///
    /// # Errors
    ///
    /// 写入失败时返回 [`DbError::Sqlite`]。
    pub fn set_setting(&self, key: &str, value: &str, at_ms: i64) -> Result<(), DbError> {
        let guard = self.connection()?;
        guard.execute(
            "INSERT INTO settings (key, value, updated_at_ms) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms",
            rusqlite::params![key, value, at_ms],
        )?;
        Ok(())
    }

    /// 数据库文件字节数（内存库返回 `None`）。
    ///
    /// # Errors
    ///
    /// 文件系统读取失败时返回 `None`（不视为错误：文件可能刚被清理）。
    #[must_use]
    pub fn file_size_bytes(&self) -> Option<u64> {
        self.path
            .as_ref()
            .and_then(|path| std::fs::metadata(path).ok())
            .map(|meta| meta.len())
    }
}

/// 打开标志：读写 + 创建 + 多线程模式 + 扩展加载关闭。
const fn open_flags() -> OpenFlags {
    OpenFlags::SQLITE_OPEN_READ_WRITE
        .union(OpenFlags::SQLITE_OPEN_CREATE)
        .union(OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .union(OpenFlags::SQLITE_OPEN_URI)
}

/// 应用 PRAGMA 基线（铁律 D12）。
///
/// WAL 只对**文件库**有意义；内存库会被 SQLite 静默忽略，因此这里显式区分，
/// 避免"以为开了 WAL 其实没有"的错觉。
fn configure_pragmas(connection: &Connection) -> Result<(), DbError> {
    let persistent = {
        let journal: String =
            connection.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))?;
        journal.eq_ignore_ascii_case("wal")
    };

    connection.pragma_update(
        None,
        "synchronous",
        if persistent { "NORMAL" } else { "OFF" },
    )?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.pragma_update(None, "temp_store", "MEMORY")?;
    connection.pragma_update(None, "wal_autocheckpoint", WAL_AUTOCHECKPOINT_PAGES)?;
    // 负值表示 KB：64 MiB 页缓存
    connection.pragma_update(None, "cache_size", -65_536)?;
    connection.busy_timeout(std::time::Duration::from_millis(BUSY_TIMEOUT_MS))?;

    if persistent {
        tracing::debug!("SQLite 已启用 WAL 模式");
    } else {
        tracing::debug!("SQLite 运行在内存库模式（WAL 不适用）");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_database_reaches_latest_schema() {
        let db = Database::open_in_memory().expect("open");
        assert_eq!(
            db.schema_version().expect("version"),
            migrations::LATEST_VERSION
        );
    }

    #[test]
    fn integrity_check_passes_on_fresh_database() {
        let db = Database::open_in_memory().expect("open");
        db.check_integrity().expect("integrity");
    }

    #[test]
    fn ping_succeeds() {
        let db = Database::open_in_memory().expect("open");
        db.ping().expect("ping");
    }

    #[test]
    fn file_database_enables_wal() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = Database::open(dir.path().join("nested.db")).expect("open");
        let guard = db.connection().expect("connection");
        let mode: String = guard
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("journal_mode");
        assert_eq!(mode.to_lowercase(), "wal");
    }

    #[test]
    fn foreign_keys_are_enforced() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("connection");
        let enabled: i64 = guard
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
            .expect("foreign_keys");
        assert_eq!(enabled, 1, "外键必须开启，否则软删除链会写坏数据");
    }

    #[test]
    fn migration_is_idempotent() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested.db");
        let first = Database::open(&path).expect("open");
        assert_eq!(
            first.schema_version().expect("v"),
            migrations::LATEST_VERSION
        );
        drop(first);
        // 再次打开：不应重复执行迁移，也不应报错
        let second = Database::open(&path).expect("reopen");
        assert_eq!(
            second.schema_version().expect("v"),
            migrations::LATEST_VERSION
        );
        second.check_integrity().expect("integrity");
    }

    #[test]
    fn schema_too_new_is_refused() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested.db");
        {
            let db = Database::open(&path).expect("open");
            let guard = db.connection().expect("connection");
            guard
                .execute_batch(&format!(
                    "PRAGMA user_version = {}",
                    migrations::LATEST_VERSION + 1
                ))
                .expect("bump version");
        }
        let err = Database::open(&path).expect_err("must refuse future schema");
        assert!(
            matches!(err, DbError::SchemaTooNew { .. }),
            "实际错误：{err:?}"
        );
    }

    #[test]
    fn settings_roundtrip_and_overwrite() {
        let db = Database::open_in_memory().expect("open");
        assert_eq!(db.setting("theme").expect("get"), None);
        db.set_setting("theme", "dark", 1).expect("set");
        assert_eq!(db.setting("theme").expect("get").as_deref(), Some("dark"));
        db.set_setting("theme", "light", 2).expect("overwrite");
        assert_eq!(db.setting("theme").expect("get").as_deref(), Some("light"));
    }

    #[test]
    fn transaction_rolls_back_on_error() {
        let db = Database::open_in_memory().expect("open");
        let result: Result<(), DbError> = db.with_transaction(|tx| {
            tx.execute(
                "INSERT INTO settings (key, value, updated_at_ms) VALUES ('k', 'v', 1)",
                [],
            )?;
            Err(DbError::NotFound {
                entity: "deliberate",
            })
        });
        assert!(result.is_err());
        assert_eq!(
            db.setting("k").expect("get"),
            None,
            "失败的事务必须整体回滚"
        );
    }

    #[test]
    fn expected_tables_exist() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("connection");
        for table in [
            "notebooks",
            "notes",
            "tags",
            "note_tags",
            "attachments",
            "note_attachments",
            "documents",
            "revisions",
            "sync_operations",
            "settings",
        ] {
            let count: i64 = guard
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .expect("query");
            assert_eq!(count, 1, "缺少表：{table}");
        }
    }
}
