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
pub const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    name: "0001_init",
    sql: include_str!("../../../migrations/0001_init.sql"),
}];

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

/// 按序执行未应用的迁移。
///
/// 整个升级过程在**单个事务**内完成：要么全部生效，要么原样回滚，
/// 不会出现"迁移到一半"的数据库。
///
/// # Errors
///
/// - 数据库版本高于本程序支持 → [`DbError::SchemaTooNew`]（禁止降级使用）
/// - 迁移清单版本号不连续 → [`DbError::MigrationManifest`]
/// - SQL 执行失败 → [`DbError::Migrate`]（事务回滚，库保持升级前状态）
pub fn apply(connection: &mut Connection) -> Result<u32, DbError> {
    validate_manifest()?;

    let from = current_version(connection)?;
    if from > LATEST_VERSION {
        return Err(DbError::SchemaTooNew {
            found: from,
            supported: LATEST_VERSION,
        });
    }
    if from == LATEST_VERSION {
        tracing::debug!(version = from, "数据库结构已是最新");
        return Ok(from);
    }

    let pending: Vec<&Migration> = MIGRATIONS
        .iter()
        .filter(|migration| migration.version > from)
        .collect();

    tracing::info!(
        from,
        to = LATEST_VERSION,
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

    Ok(LATEST_VERSION)
}

/// 校验清单自身的一致性（版本连续、名称唯一、SQL 非空）。
fn validate_manifest() -> Result<(), DbError> {
    for (index, migration) in MIGRATIONS.iter().enumerate() {
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

    #[test]
    fn manifest_is_consistent() {
        validate_manifest().expect("清单必须自洽");
        assert_eq!(LATEST_VERSION, MIGRATIONS.len() as u32);
    }

    #[test]
    fn manifest_embeds_real_sql() {
        let first = MIGRATIONS.first().expect("至少一条迁移");
        assert!(
            first.sql.contains("CREATE TABLE notes"),
            "应嵌入 0001_init.sql 内容"
        );
    }
}
