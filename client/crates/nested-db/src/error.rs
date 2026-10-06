//! 存储层错误（铁律 R3：库层用具体错误类型，禁止用 `String` 向上传播）。

use thiserror::Error;

/// 存储层错误。向上会由 `nested-core` 映射为对 UI 友好的结构化错误
/// （`DatabaseError` / `MigrationError` …），**禁止**把 `rusqlite::Error`
/// 原样透传给 Flutter（铁律 E1/E2）。
#[derive(Debug, Error)]
pub enum DbError {
    /// SQLite 底层错误。
    #[error("数据库操作失败：{0}")]
    Sqlite(#[from] rusqlite::Error),

    /// 迁移执行失败（事务已回滚）。
    #[error("迁移 {version}（{name}）执行失败：{source}")]
    Migrate {
        /// 失败的迁移版本。
        version: u32,
        /// 失败的迁移名称。
        name: &'static str,
        /// 底层错误。
        #[source]
        source: rusqlite::Error,
    },

    /// 迁移清单自身不合法（开发期错误，不应出现在发布版）。
    #[error("迁移清单不合法：{reason}")]
    MigrationManifest {
        /// 原因描述。
        reason: &'static str,
    },

    /// 数据库结构版本高于本程序支持，禁止继续使用（防止降级写坏数据）。
    #[error("数据库结构版本 {found} 高于本程序支持的 {supported}，请升级应用后再打开")]
    SchemaTooNew {
        /// 库中记录的版本。
        found: u32,
        /// 本程序支持的版本。
        supported: u32,
    },

    /// `PRAGMA user_version` 取值超出 u32 范围。
    #[error("数据库版本号异常：{raw}")]
    VersionOutOfRange {
        /// 原始取值。
        raw: i64,
    },

    /// `PRAGMA integrity_check` 未通过。
    #[error("数据库完整性校验失败：{detail}")]
    IntegrityCheckFailed {
        /// SQLite 报告的细节。
        detail: String,
    },

    /// 请求的记录不存在。
    #[error("记录不存在：{entity}")]
    NotFound {
        /// 实体名称，如 `"note"`。
        entity: &'static str,
    },

    /// 唯一约束冲突（如标签重名、同一内容的附件重复插入）。
    #[error("唯一约束冲突：{entity}")]
    Conflict {
        /// 实体名称。
        entity: &'static str,
    },

    /// 存储的字节无法解析为领域模型。
    #[error("数据损坏：{entity} 字段无法解析")]
    Corrupt {
        /// 实体名称。
        entity: &'static str,
    },

    /// 重入访问连接：已经持有一个连接借用，却又尝试再次获取。
    ///
    /// **这是一条开发期错误，不是运行时故障**：`std::sync::Mutex` 不可重入，
    /// 若不做检测，这种误用会表现为"进程静默挂起"（不报错、不 panic），
    /// 极难排查。因此这里主动把它变成一条明确的错误。
    #[error("重入访问数据库连接：已持有一个连接借用，不能再次获取（会死锁）")]
    ReentrantLock,

    /// 在已有事务中又尝试开启新事务（嵌套事务）。
    ///
    /// 同样属于开发期错误：嵌套会让事务边界不可预测——外层回滚时内层已经提交的内容
    /// 会留下，破坏"一次业务操作 = 一个事务"（铁律 D1）。
    #[error("不允许嵌套事务：当前已处于事务中，请复用该事务而不是再开一个")]
    NestedTransaction,

    /// 连接互斥锁已中毒（持锁线程在持锁期间 panic）。
    #[error("数据库连接锁已中毒：持锁线程曾 panic，连接状态不可信")]
    LockPoisoned,

    /// 数据库句柄已关闭。
    #[error("数据库已关闭")]
    Closed,
}

/// 存储层 Result 别名。
pub type DbResult<T> = std::result::Result<T, DbError>;
