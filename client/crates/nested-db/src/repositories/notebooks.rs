//! 笔记本仓储。
//!
//! 删除一律软删除（铁律 T7）：本模块**不提供**物理删除函数。

use nested_model::{Id, Notebook};
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::DbError;
use crate::rowmap::{id_at, optional_id_at, optional_timestamp_at, timestamp_at};

/// 统一列顺序，供所有 SELECT 复用，避免"某处少读一列"的错位 bug。
const COLUMNS: &str = "id, name, parent_id, created_at_ms, updated_at_ms, deleted_at_ms";

/// 从一行映射出 [`Notebook`]（错误类型为 `rusqlite::Error`，见 `rowmap` 模块说明）。
fn map_row(row: &Row<'_>) -> rusqlite::Result<Notebook> {
    Ok(Notebook {
        id: id_at(row, 0, "notebook")?,
        name: row.get(1)?,
        parent_id: optional_id_at(row, 2, "notebook")?,
        created_at_ms: timestamp_at(row, 3)?.as_millis(),
        updated_at_ms: timestamp_at(row, 4)?.as_millis(),
        deleted_at_ms: optional_timestamp_at(row, 5)?.map(|ts| ts.as_millis()),
    })
}

/// 插入一个笔记本。
///
/// # Errors
///
/// 主键冲突或写入失败时返回 [`DbError`]。
pub fn insert(connection: &Connection, notebook: &Notebook) -> Result<(), DbError> {
    connection.execute(
        "INSERT INTO notebooks (id, name, parent_id, created_at_ms, updated_at_ms, deleted_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            notebook.id.as_bytes(),
            notebook.name,
            notebook.parent_id.as_ref().map(|id| id.as_bytes().to_vec()),
            notebook.created_at_ms,
            notebook.updated_at_ms,
            notebook.deleted_at_ms,
        ],
    )?;
    Ok(())
}

/// 按标识读取。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]；不存在返回 `Ok(None)`。
pub fn get(connection: &Connection, id: &Id) -> Result<Option<Notebook>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM notebooks WHERE id = ?1");
    connection
        .query_row(&sql, params![id.as_bytes()], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 列出全部未删除笔记本，按名称排序。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_all(connection: &Connection) -> Result<Vec<Notebook>, DbError> {
    let sql =
        format!("SELECT {COLUMNS} FROM notebooks WHERE deleted_at_ms IS NULL ORDER BY name ASC");
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map([], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 列出某个父节点下的子笔记本。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_children(
    connection: &Connection,
    parent_id: Option<&Id>,
) -> Result<Vec<Notebook>, DbError> {
    let sql = format!(
        "SELECT {COLUMNS} FROM notebooks
         WHERE deleted_at_ms IS NULL
           AND ((?1 IS NULL AND parent_id IS NULL) OR parent_id = ?1)
         ORDER BY name ASC"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![parent_id.map(|id| id.as_bytes().to_vec())], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 重命名。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn rename(connection: &Connection, id: &Id, name: &str, at_ms: i64) -> Result<(), DbError> {
    let changed = connection.execute(
        "UPDATE notebooks SET name = ?2, updated_at_ms = ?3
         WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), name, at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "notebook" });
    }
    Ok(())
}

/// 软删除（移入回收站）。
///
/// **注意**：不会级联删除子笔记本与笔记——级联策略由 `nested-core` 的业务规则决定，
/// 仓储层只负责一次写入（铁律 A7）。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn soft_delete(connection: &Connection, id: &Id, at_ms: i64) -> Result<(), DbError> {
    let changed = connection.execute(
        "UPDATE notebooks SET deleted_at_ms = ?2, updated_at_ms = ?2
         WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "notebook" });
    }
    Ok(())
}

/// 从回收站恢复。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn restore(connection: &Connection, id: &Id, at_ms: i64) -> Result<(), DbError> {
    let changed = connection.execute(
        "UPDATE notebooks SET deleted_at_ms = NULL, updated_at_ms = ?2
         WHERE id = ?1 AND deleted_at_ms IS NOT NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "notebook" });
    }
    Ok(())
}

/// 统计未删除笔记本数量。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn count(connection: &Connection) -> Result<i64, DbError> {
    let total: i64 = connection.query_row(
        "SELECT COUNT(*) FROM notebooks WHERE deleted_at_ms IS NULL",
        [],
        |row| row.get(0),
    )?;
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;

    const NOW: i64 = 1_700_000_000_000;

    fn notebook(name: &str) -> Notebook {
        Notebook::new(name, None, NOW).expect("valid notebook")
    }

    #[test]
    fn insert_then_get_roundtrips() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let original = notebook("工作");
        insert(&guard, &original).expect("insert");
        let loaded = get(&guard, &original.id).expect("get").expect("exists");
        assert_eq!(loaded, original);
    }

    #[test]
    fn get_missing_returns_none_not_error() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        assert!(get(&guard, &Id::new()).expect("get").is_none());
    }

    #[test]
    fn list_all_excludes_soft_deleted_and_sorts_by_name() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        insert(&guard, &notebook("beta")).expect("insert");
        insert(&guard, &notebook("Alpha")).expect("insert");
        let gone = notebook("删掉的");
        insert(&guard, &gone).expect("insert");
        soft_delete(&guard, &gone.id, NOW + 1).expect("soft delete");

        let names: Vec<String> = list_all(&guard)
            .expect("list")
            .into_iter()
            .map(|n| n.name)
            .collect();
        assert_eq!(names, vec!["Alpha".to_owned(), "beta".to_owned()]);
        assert_eq!(count(&guard).expect("count"), 2);
    }

    #[test]
    fn nested_notebooks_are_listed_by_parent() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let root = notebook("root");
        insert(&guard, &root).expect("insert root");
        let child = Notebook::new("child", Some(root.id), NOW).expect("valid");
        insert(&guard, &child).expect("insert child");

        let roots = list_children(&guard, None).expect("roots");
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0].id, root.id);

        let children = list_children(&guard, Some(&root.id)).expect("children");
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].id, child.id);
    }

    #[test]
    fn rename_updates_timestamp() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let item = notebook("旧名");
        insert(&guard, &item).expect("insert");
        rename(&guard, &item.id, "新名", NOW + 500).expect("rename");
        let loaded = get(&guard, &item.id).expect("get").expect("exists");
        assert_eq!(loaded.name, "新名");
        assert_eq!(loaded.updated_at_ms, NOW + 500);
    }

    #[test]
    fn rename_missing_is_not_found() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let err = rename(&guard, &Id::new(), "x", NOW).expect_err("must fail");
        assert!(matches!(err, DbError::NotFound { entity: "notebook" }));
    }

    #[test]
    fn soft_delete_then_restore_is_reversible() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let item = notebook("回收站往返");
        insert(&guard, &item).expect("insert");

        soft_delete(&guard, &item.id, NOW + 1).expect("delete");
        assert!(
            get(&guard, &item.id)
                .expect("get")
                .expect("exists")
                .is_deleted()
        );

        restore(&guard, &item.id, NOW + 2).expect("restore");
        assert!(
            !get(&guard, &item.id)
                .expect("get")
                .expect("exists")
                .is_deleted()
        );
    }

    #[test]
    fn double_soft_delete_is_reported() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let item = notebook("重复删除");
        insert(&guard, &item).expect("insert");
        soft_delete(&guard, &item.id, NOW + 1).expect("first");
        assert!(soft_delete(&guard, &item.id, NOW + 2).is_err());
    }

    #[test]
    fn row_is_never_physically_removed_by_soft_delete() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let item = notebook("墓碑");
        insert(&guard, &item).expect("insert");
        soft_delete(&guard, &item.id, NOW + 1).expect("delete");
        let total: i64 = guard
            .query_row("SELECT COUNT(*) FROM notebooks", [], |row| row.get(0))
            .expect("count");
        assert_eq!(total, 1, "软删除必须保留行（同步需要墓碑，铁律 D9）");
    }
}
