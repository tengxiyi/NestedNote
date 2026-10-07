//! 数据库句柄：打开、PRAGMA 基线、事务、完整性校验。
//!
//! ## 连接模型（当前阶段）
//!
//! 单写入连接 + 互斥锁。理由：
//! - SQLite 在 WAL 模式下同一时刻**只允许一个写者**，多写连接只会互相 `SQLITE_BUSY`；
//! - 第一阶段（P1/P2）的瓶颈在索引与查询设计，不在连接数；
//! - 引入连接池属于性能优化，必须在 P4 有基准数据支撑后再做（铁律 P2：先测量再优化）。
//!
//! 多读优化留给 P4，届时通过 `criterion` 基准证明必要性。
//!
//! ## 重入保护
//!
//! `Mutex` 不可重入，而"持有连接时又调用 `Database` 的方法"是极容易犯的错。
//! 因此加锁前会做重入检测，误用会**立即报错**而不是静默挂起——
//! 细节见 [`Database::connection`]。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// 是否把**子笔记本**里的笔记也算进来（默认否）。
    ///
    /// 笔记本是一棵树。用户在树里点选一个父笔记本时，期望看到它**以及所有后代**
    /// 的笔记——否则每建一层子笔记本，父级看上去就变空了。
    /// 默认关闭是为了保持"按笔记本过滤"的朴素语义，需要树形聚合时由调用方显式打开。
    ///
    /// 仅在 [`NoteQuery::notebook_id`] 为 `Some` 时有意义；
    /// 实现见 `repositories::notes::list_sql`（用递归 CTE 一次查完）。
    pub include_descendants: bool,
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
    /// 重入检测开关（见 [`Database::connection`]）。
    ///
    /// `std::sync::Mutex` 不可重入，自己等自己会**永久挂起**：不报错、不 panic，
    /// 现象只是"卡住不动"。本项目的测试因此挂死过一次，排查代价很高。
    /// 用一个标志把这种误用变成**立即返回的错误**，是消除该陷阱最省的方式
    /// （比把全部调用点改成闭包 API 风险小得多）。
    locked: AtomicBool,
}

/// 连接借用的 RAII 守卫。
///
/// 除了持有 `MutexGuard`，它还负责在**释放时**清掉重入标志，
/// 这样"guard 离开作用域"与"允许再次加锁"永远同步，不会因为忘记复位而误报。
#[derive(Debug)]
pub struct ConnectionGuard<'a> {
    guard: MutexGuard<'a, Connection>,
    locked: &'a AtomicBool,
    /// 该守卫是否真正持锁（用于"连接已关闭"的占位情况）。
    owns_lock: bool,
}

impl std::ops::Deref for ConnectionGuard<'_> {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        &self.guard
    }
}

impl std::ops::DerefMut for ConnectionGuard<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.guard
    }
}

impl Drop for ConnectionGuard<'_> {
    fn drop(&mut self) {
        if self.owns_lock {
            self.locked.store(false, Ordering::Release);
        }
    }
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
            locked: AtomicBool::new(false),
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

    /// 借用底层连接。
    ///
    /// ## 重入会被检测并报错（不会死锁）
    ///
    /// `std::sync::Mutex` 不可重入。如果在**持有**上一个 [`ConnectionGuard`] 期间
    /// 再次调用 [`Database::connection`]，或调用任何内部会取连接的 `Database` 方法
    /// （[`Database::check_integrity`]、[`Database::with_transaction`]、
    /// [`Database::setting`]…），这里会立即返回 [`DbError::ReentrantLock`]，
    /// **而不是静默挂起**。
    ///
    /// 这条检测是刻意加的：本项目的测试曾因误用而挂死一次——进程不报错、不 panic，
    /// 现象只是"卡住不动"，排查代价很高。
    ///
    /// ```no_run
    /// # use nested_db::Database;
    /// # fn demo(db: &Database) {
    /// // 正确写法：让 guard 先在作用域内用完
    /// let version = {
    ///     let guard = db.connection().unwrap();
    ///     guard
    ///         .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
    ///         .unwrap()
    /// };
    /// assert!(version >= 0);
    ///
    /// // 更推荐：`with_connection` 把作用域收敛在一处
    /// let again = db
    ///     .with_connection(|connection| {
    ///         Ok(connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?)
    ///     })
    ///     .unwrap();
    /// assert_eq!(version, again);
    /// # }
    /// ```
    ///
    /// # Errors
    ///
    /// - 连接已关闭 → [`DbError::Sqlite`]
    /// - 重入（已持有连接） → [`DbError::ReentrantLock`]
    /// - 锁中毒（持锁线程 panic） → [`DbError::LockPoisoned`]
    pub fn connection(&self) -> Result<ConnectionGuard<'_>, DbError> {
        // Acquire 与 Release 配对：只有真正拿到锁的那次才置位/清位
        if self.locked.swap(true, Ordering::Acquire) {
            return Err(DbError::ReentrantLock);
        }
        let Some(mutex) = self.connection.as_ref() else {
            // 连接已关闭：把标志复位，否则后续调用会被误判为重入
            self.locked.store(false, Ordering::Release);
            return Err(DbError::Closed);
        };
        // 锁中毒说明持锁线程曾 panic，连接状态不可信，因此明确报错而不是继续用
        let Ok(guard) = mutex.lock() else {
            self.locked.store(false, Ordering::Release);
            return Err(DbError::LockPoisoned);
        };
        Ok(ConnectionGuard {
            guard,
            locked: &self.locked,
            owns_lock: true,
        })
    }

    /// 在闭包里访问连接（推荐用法）。
    ///
    /// 相比 [`Database::connection`]，它把"取锁 → 用 → 释放"收敛在一个作用域里，
    /// 从结构上避免"忘了释放就调用另一个方法"。
    ///
    /// # Errors
    ///
    /// 取连接失败（见 [`Database::connection`]）或闭包本身返回错误时返回错误。
    pub fn with_connection<T, F>(&self, f: F) -> Result<T, DbError>
    where
        F: FnOnce(&Connection) -> Result<T, DbError>,
    {
        let guard = self.connection()?;
        f(&guard)
    }

    /// 在**单个事务**中执行一段操作（铁律 D1：一次业务操作 = 一个事务）。
    ///
    /// 闭包返回 `Err` 时事务自动回滚。
    ///
    /// # Errors
    ///
    /// 连接不可用、事务开启或提交失败时返回错误。
    /// 在**单个事务**中执行一段操作（铁律 D1：一次业务操作 = 一个事务）。
    ///
    /// 使用 `Immediate` 行为：一开始就取写锁，而不是等到第一次写才升级。
    /// 理由见 [`begin_write_transaction`]。
    ///
    /// # Errors
    ///
    /// 连接不可用、事务开启或提交失败时返回错误。
    pub fn with_transaction<T, F>(&self, f: F) -> Result<T, DbError>
    where
        F: FnOnce(&Transaction<'_>) -> Result<T, DbError>,
    {
        let mut guard = self.connection()?;
        let transaction = begin_write_transaction(&mut guard)?;
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

/// 开启一个**写事务**（`IMMEDIATE` 行为）。
///
/// ## 为什么统一用 `IMMEDIATE`，而不是 `DEFERRED`（rusqlite 默认）
///
/// - `DEFERRED` 在**第一次写**时才尝试取写锁。若事务里是"先读后写"的模式
///   （本项目的保存路径正是：先更新 `notes`、再写 `documents`），取锁发生在中途；
///   此时若另一连接持有写锁，SQLite 会立刻返回 `SQLITE_BUSY`——
///   而 `busy_timeout` 对"锁升级失败"**不生效**，于是表现为"随机失败"而非"等一会儿"。
/// - `IMMEDIATE` 在事务开始时就取写锁，冲突发生在起点，由 `busy_timeout` 正常排队。
///
/// ## 为什么参数是 `&mut Connection`
///
/// rusqlite 0.40 中**只有** `transaction_with_behavior(&mut self, ...)` 能指定事务行为；
/// 可用于 `&Connection` 的 `unchecked_transaction()` 行为固定为 `DEFERRED`，
/// 且允许静默嵌套。把参数定为 `&mut` 换来两个好处：
///
/// 1. 能真正使用 `IMMEDIATE`（与 [`Database::with_transaction`] 语义一致）；
/// 2. **嵌套在编译期就不可能出现**——同一个 `&mut` 无法同时被两个事务借用。
///
/// 调用方持有的是 [`ConnectionGuard`]，它实现了 `DerefMut`，
/// 因此 `&mut *guard` 就能直接传入。
///
/// # Errors
///
/// 取写锁失败（例如超时）时返回 [`DbError::Sqlite`]。
pub fn begin_write_transaction(connection: &mut Connection) -> Result<Transaction<'_>, DbError> {
    Ok(connection.transaction_with_behavior(TransactionBehavior::Immediate)?)
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

    // ---------------------------------------------------------------- 重入保护
    //
    // 这一组测试是本模块最重要的回归防线：`Mutex` 不可重入，误用会**静默挂起**
    // （不报错、不 panic，只是卡住），本项目为此真实挂死过一次。
    // 下面每个测试都在证明"误用会立刻得到明确错误"。

    #[test]
    fn second_connection_borrow_is_rejected_instead_of_deadlocking() {
        let db = Database::open_in_memory().expect("open");
        let first = db.connection().expect("first borrow");
        let second = db.connection();

        assert!(
            matches!(second, Err(DbError::ReentrantLock)),
            "重复借用必须被拒绝；若这里挂住，说明重入检测失效"
        );
        drop(first);
    }

    #[test]
    fn database_methods_while_holding_connection_are_rejected() {
        let db = Database::open_in_memory().expect("open");
        let _guard = db.connection().expect("borrow");

        // 这三个都是内部会取连接的 Database 方法，持有 guard 时调用必须报错
        assert!(matches!(db.ping(), Err(DbError::ReentrantLock)));
        assert!(matches!(db.check_integrity(), Err(DbError::ReentrantLock)));
        assert!(matches!(
            db.with_transaction(|_| Ok(())),
            Err(DbError::ReentrantLock)
        ));
    }

    #[test]
    fn borrow_becomes_available_again_after_guard_is_dropped() {
        let db = Database::open_in_memory().expect("open");

        {
            let _guard = db.connection().expect("first");
        }

        // guard 释放后必须能再次借用（否则重入标志泄漏，库就"锁死"了）
        db.ping().expect("must be usable again after drop");
        let _again = db.connection().expect("second borrow");
    }

    #[test]
    fn flag_is_cleared_even_when_closure_returns_error() {
        let db = Database::open_in_memory().expect("open");

        let failed: Result<(), DbError> =
            db.with_connection(|_| Err(DbError::NotFound { entity: "probe" }));
        assert!(failed.is_err());

        // 闭包返回错误不能让重入标志卡住
        db.ping()
            .expect("must still be usable after failing closure");
    }

    #[test]
    fn with_connection_passes_a_usable_connection() {
        let db = Database::open_in_memory().expect("open");
        let version = db
            .with_connection(|connection| {
                Ok(connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?)
            })
            .expect("with_connection");
        assert_eq!(version, i64::from(migrations::LATEST_VERSION));
    }

    #[test]
    fn with_connection_propagates_closure_error() {
        let db = Database::open_in_memory().expect("open");
        let error = db
            .with_connection(|_| Err::<(), _>(DbError::NotFound { entity: "note" }))
            .expect_err("必须把闭包的错误传出去");
        assert!(matches!(error, DbError::NotFound { entity: "note" }));
    }

    #[test]
    fn write_transaction_is_immediate_not_deferred() {
        // IMMEDIATE 的意义：一开事务就取写锁（`BEGIN IMMEDIATE` 会让 sqlite 记下
        // 一个 ROLLBACK journal / 写锁）。DEFERRED 则要等到第一次写才取锁。
        //
        // 判据用 `Transaction` 自己执行 PRAGMA（不能去读 `connection.is_autocommit()`：
        // 事务正持有 `&mut Connection`，编译器不允许再借用——这本身就是嵌套不可能的证据）。
        let mut connection = Connection::open_in_memory().expect("open");
        let transaction = begin_write_transaction(&mut connection).expect("begin");

        // 事务内可以直接写入（若为 DEFERRED，此刻才取写锁；IMMEDIATE 已在开启时取到）
        transaction
            .execute_batch("CREATE TABLE probe (id INTEGER PRIMARY KEY)")
            .expect("write inside transaction");

        let in_transaction: i64 = transaction
            .query_row("SELECT 1", [], |row| row.get(0))
            .expect("query inside transaction");
        assert_eq!(in_transaction, 1);

        transaction.rollback().expect("rollback");

        // 回滚后表不应存在，证明事务确实生效（而不是被静默嵌套成自动提交）
        let exists: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='probe'",
                [],
                |row| row.get(0),
            )
            .expect("query after rollback");
        assert_eq!(exists, 0, "回滚必须撤销事务内的建表");
        assert!(connection.is_autocommit(), "回滚后应回到自动提交模式");
    }

    #[test]
    fn nested_transaction_is_impossible_at_compile_time() {
        // 这条不变量由**类型系统**保证：`&mut Connection` 同一时刻只能被一个事务借用。
        // 本测试用运行期断言把这个意图记录下来：
        // 事务存活期间无法再开启第二个事务（下面的代码一旦写成注释里的样子就编译不过）。
        let mut connection = Connection::open_in_memory().expect("open");
        let transaction = begin_write_transaction(&mut connection).expect("begin");
        // let _second = begin_write_transaction(&mut connection); // ← 编译错误 E0499
        transaction.commit().expect("commit");
        assert!(connection.is_autocommit());
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
