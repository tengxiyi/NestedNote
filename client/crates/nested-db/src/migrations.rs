//! 迁移体系（铁律 Q1 / Q2 / Q3 / Q10）。
//!
//! ## 规则
//!
//! - 所有结构变更**必须**新增一个 `NNNN_name.sql` 文件并登记到 [`MIGRATIONS`]。
//! - **已发布**的迁移文件**禁止**修改：CI 会用 `tests/migration_guard.rs` 校验
//!   文件哈希清单与目录内容一致，改动历史文件会导致测试失败。
//! - 启动时按 `PRAGMA user_version` 顺序执行，**整体在一个事务里**；
//!   失败即中止，**禁止**带病启动（Q3）。
//!
//! 为什么要校验历史文件：用户库已经按旧版迁移过了，事后改文件会让
//! "新装用户"和"老用户"的 schema 悄悄分叉——这类问题只在生产爆雷。

use rusqlite::Connection;

use crate::DbError;

/// 一条迁移。
#[derive(Debug, Clone, Copy)]
pub struct Migration {
    /// 版本号，必须从 1 开始连续递增。
    pub version: u32,
    /// 名称（与文件名一致，便于定位）。
    pub name: &'static str,
    /// SQL 内容（编译期嵌入，避免运行时找不到文件）。
    pub sql: &'static str,
}

/// 内置迁移清单。新增迁移时**只能追加**。
pub const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "0001_init",
        sql: include_str!("../../../migrations/0001_init.sql"),
    },
    // 0002：修正 sync_operations 的外键设计。
    // 起因（技术债 #12 的连带发现）：同步队列要承载笔记本/标签的变更，
    // 而 0001 把 `note_id` 定义为 `REFERENCES notes (id)`，
    // 写入非笔记实体时会触发 787 FOREIGN KEY constraint failed。
    Migration {
        version: 2,
        name: "0002_sync_operations_entity",
        sql: include_str!("../../../migrations/0002_sync_operations_entity.sql"),
    },
    // 0003：为修订保存内容快照（"修订对比"的数据基础）。
    // 起因：`revisions` 只存元数据，没有内容可对比。
    // 决策依据：docs/adr/0001-修订内容用完整快照.md
    Migration {
        version: 3,
        name: "0003_revision_documents",
        sql: include_str!("../../../migrations/0003_revision_documents.sql"),
    },
    // 0004：活动日志（铁律 T1"可追溯"的兑现）。
    // 只记维护/破坏性事件（回收站清理、附件 GC、完整性核对）；
    // 笔记级变更修订历史已经覆盖，重复记一遍是噪音。
    Migration {
        version: 4,
        name: "0004_activity_log",
        sql: include_str!("../../../migrations/0004_activity_log.sql"),
    },
];

/// 当前程序支持的最高数据库版本。
pub const LATEST_VERSION: u32 = match MIGRATIONS.last() {
    Some(last) => last.version,
    None => 0,
};

/// 读取数据库当前版本（`PRAGMA user_version`）。
///
/// # Errors
///
/// 读取 PRAGMA 失败时返回 [`DbError::Sqlite`]。
pub fn current_version(connection: &Connection) -> Result<u32, DbError> {
    let raw: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    u32::try_from(raw).map_err(|_| DbError::VersionOutOfRange { raw })
}

/// 按序执行**内置**清单中未应用的迁移。见 [`apply_manifest`]。
///
/// # Errors
///
/// 见 [`apply_manifest`]。
pub fn apply(connection: &mut Connection) -> Result<u32, DbError> {
    apply_manifest(connection, MIGRATIONS, LATEST_VERSION)
}

/// 按序执行给定清单中未应用的迁移。
///
/// 整个升级过程在**单个事务**内完成：要么全部生效，要么原样回滚，
/// 不会出现"迁移到一半"的数据库。
///
/// ## 为什么清单是参数而不是直接用 [`MIGRATIONS`]
///
/// 迁移的失败路径（SQL 出错时的回滚、清单不自洽时的拒绝启动）恰恰是**最需要测试**
/// 的部分——"迁移失败留下半截状态"是最难排查的一类事故。把清单作为参数注入，
/// 测试就能构造一条必然失败的迁移来验证回滚，而不必真的去破坏内置迁移。
/// 生产路径通过 [`apply`] 固定使用内置清单。
///
/// # Errors
///
/// - 数据库版本高于本程序支持 → [`DbError::SchemaTooNew`]（禁止降级使用）
/// - 清单版本号不连续或 SQL 为空 → [`DbError::MigrationManifest`]
/// - SQL 执行失败 → [`DbError::Migrate`]（事务回滚，库保持升级前状态）
pub fn apply_manifest(
    connection: &mut Connection,
    migrations: &[Migration],
    latest_version: u32,
) -> Result<u32, DbError> {
    validate_manifest(migrations)?;

    let from = current_version(connection)?;
    if from > latest_version {
        return Err(DbError::SchemaTooNew {
            found: from,
            supported: latest_version,
        });
    }
    if from == latest_version {
        tracing::debug!(version = from, "数据库结构已是最新");
        return Ok(from);
    }

    let pending: Vec<&Migration> = migrations
        .iter()
        .filter(|migration| migration.version > from)
        .collect();

    tracing::info!(
        from,
        to = latest_version,
        count = pending.len(),
        "开始执行数据库迁移"
    );

    let transaction = connection.transaction()?;
    for migration in pending {
        transaction
            .execute_batch(migration.sql)
            .map_err(|source| DbError::Migrate {
                version: migration.version,
                name: migration.name,
                source,
            })?;
        // user_version 不支持参数绑定，这里拼的是**已校验为 u32 的数字**，
        // 不含任何用户输入，因此不违反铁律 Q4（Q4 禁止的是拼接用户可控内容）。
        transaction.execute_batch(&format!("PRAGMA user_version = {}", migration.version))?;
        tracing::info!(
            version = migration.version,
            name = migration.name,
            "迁移已应用"
        );
    }
    transaction.commit()?;

    Ok(latest_version)
}

/// 校验清单自身的一致性（版本从 1 连续递增、SQL 非空）。
fn validate_manifest(migrations: &[Migration]) -> Result<(), DbError> {
    for (index, migration) in migrations.iter().enumerate() {
        let expected = u32::try_from(index).unwrap_or(u32::MAX) + 1;
        if migration.version != expected {
            return Err(DbError::MigrationManifest {
                reason: "版本号必须从 1 开始连续递增",
            });
        }
        if migration.sql.trim().is_empty() {
            return Err(DbError::MigrationManifest {
                reason: "迁移 SQL 不得为空",
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;

    /// 一条只创建单表的合法迁移，用于构造测试清单。
    const OK_SQL: &str = "CREATE TABLE probe (id INTEGER PRIMARY KEY);";
    /// 一条必然失败的迁移（语法错误）。
    const BROKEN_SQL: &str = "CREATE TABLE";

    /// 打开一个**未经迁移**的裸连接（`user_version = 0`）。
    ///
    /// 不能用 `Database::open_in_memory()`：它内部会直接应用内置清单，
    /// 打开后版本就已经是最新，无法用来测试"从旧版本升级"的路径。
    fn bare_connection() -> Connection {
        let connection = Connection::open_in_memory().expect("open in memory");
        connection
            .busy_timeout(std::time::Duration::from_millis(5000))
            .expect("busy_timeout");
        connection
    }

    fn manifest(entries: &[(u32, &'static str, &'static str)]) -> Vec<Migration> {
        entries
            .iter()
            .map(|(version, name, sql)| Migration {
                version: *version,
                name,
                sql,
            })
            .collect()
    }

    #[test]
    fn builtin_manifest_is_consistent() {
        validate_manifest(MIGRATIONS).expect("内置清单必须自洽");
        assert_eq!(LATEST_VERSION, MIGRATIONS.len() as u32);
    }

    #[test]
    fn builtin_manifest_embeds_real_sql() {
        let first = MIGRATIONS.first().expect("至少一条迁移");
        assert!(
            first.sql.contains("CREATE TABLE notes"),
            "应嵌入 0001_init.sql 内容"
        );
    }

    #[test]
    fn manifest_rejects_non_sequential_versions() {
        let bad = manifest(&[(1, "0001_a", OK_SQL), (3, "0003_c", OK_SQL)]);
        let error = validate_manifest(&bad).expect_err("版本跳跃必须被拒绝");
        assert!(matches!(error, DbError::MigrationManifest { .. }));
    }

    #[test]
    fn manifest_rejects_empty_sql() {
        let bad = manifest(&[(1, "0001_a", "   \n  ")]);
        let error = validate_manifest(&bad).expect_err("空 SQL 必须被拒绝");
        assert!(matches!(error, DbError::MigrationManifest { .. }));
    }

    #[test]
    fn empty_manifest_is_valid_and_noop() {
        let mut connection = bare_connection();
        let version = apply_manifest(&mut connection, &[], 0).expect("apply");
        assert_eq!(version, 0);
        assert_eq!(current_version(&connection).expect("version"), 0);
    }

    #[test]
    fn injectable_manifest_is_applied_and_bumps_version() {
        let mut connection = bare_connection();
        let list = manifest(&[(1, "0001_probe", OK_SQL)]);

        let version = apply_manifest(&mut connection, &list, 1).expect("apply");
        assert_eq!(version, 1);
        assert_eq!(current_version(&connection).expect("version"), 1);

        let count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='probe'",
                [],
                |row| row.get(0),
            )
            .expect("query");
        assert_eq!(count, 1);
    }

    #[test]
    fn already_current_database_is_left_untouched() {
        let mut connection = bare_connection();
        // 先升到 1
        apply_manifest(&mut connection, &manifest(&[(1, "0001_probe", OK_SQL)]), 1).expect("first");
        // 再次执行同一清单：应当是 no-op，不报错也不重复建表
        let version = apply_manifest(&mut connection, &manifest(&[(1, "0001_probe", OK_SQL)]), 1)
            .expect("second");
        assert_eq!(version, 1);
    }

    #[test]
    fn schema_too_new_is_refused() {
        let mut connection = bare_connection();
        connection
            .execute_batch(&format!("PRAGMA user_version = {}", LATEST_VERSION + 5))
            .expect("bump");
        let error = apply_manifest(&mut connection, MIGRATIONS, LATEST_VERSION)
            .expect_err("版本过高必须拒绝");
        assert!(matches!(error, DbError::SchemaTooNew { .. }));
    }

    #[test]
    fn failing_migration_rolls_back_entirely() {
        let mut connection = bare_connection();

        // 第二条迁移语法错误：第一条必须一起回滚，版本不得前进
        let list = manifest(&[(1, "0001_ok", OK_SQL), (2, "0002_broken", BROKEN_SQL)]);
        let error = apply_manifest(&mut connection, &list, 2).expect_err("必须失败");
        assert!(
            matches!(error, DbError::Migrate { version: 2, .. }),
            "实际：{error:?}"
        );

        assert_eq!(
            current_version(&connection).expect("version"),
            0,
            "失败后版本必须保持升级前的值"
        );
        let probe_exists: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='probe'",
                [],
                |row| row.get(0),
            )
            .expect("query");
        assert_eq!(probe_exists, 0, "失败的事务不得留下第一条迁移建立的表");
    }

    #[test]
    fn failing_migration_keeps_previous_version_when_upgrading() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = Database::open(dir.path().join("nested.db")).expect("open");

        {
            let mut guard = db.connection().expect("conn");
            let before = current_version(&guard).expect("version");
            assert_eq!(before, LATEST_VERSION);

            // 模拟"下一版迁移写错了"：在**全部已发布迁移之后**追加一条必然失败的迁移。
            // 注意不能简单用版本 2 当"坏迁移"——真实清单里版本 2 已经存在，
            // 那样会被 `from == latest_version` 判为"无需升级"而根本不执行。
            let mut list: Vec<Migration> = MIGRATIONS.to_vec();
            list.push(Migration {
                version: LATEST_VERSION + 1,
                name: "9999_broken",
                sql: BROKEN_SQL,
            });
            let next = LATEST_VERSION + 1;

            let error = apply_manifest(&mut guard, &list, next).expect_err("必须失败");
            assert!(matches!(error, DbError::Migrate { version, .. } if version == next));
            assert_eq!(
                current_version(&guard).expect("version"),
                LATEST_VERSION,
                "升级失败不得推进版本号"
            );
            // 把 guard 的作用域收在这里：下面 check_integrity() 需要重新加锁，
            // 若在此处仍持有连接锁会直接死锁（本测试最初就是这么挂住的）。
        }

        // 库里原有数据仍然可用（回滚没有破坏它）
        db.check_integrity().expect("integrity");
    }

    #[test]
    fn migrate_error_carries_version_and_name_for_diagnosis() {
        let mut connection = bare_connection();
        let list = manifest(&[(1, "0001_broken", BROKEN_SQL)]);
        let error = apply_manifest(&mut connection, &list, 1).expect_err("必须失败");
        let text = error.to_string();
        assert!(
            text.contains("0001_broken"),
            "错误信息应含迁移名便于定位：{text}"
        );
        assert!(text.contains('1'), "错误信息应含版本号：{text}");
    }
}
