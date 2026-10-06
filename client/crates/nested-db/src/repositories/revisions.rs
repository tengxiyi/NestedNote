//! 修订记录仓储（铁律 T6：每一次修改必须可追踪）。
//!
//! 本模块只**追加**，不修改、不删除：修订历史是审计材料。

use nested_model::{Id, Revision};
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::DbError;
use crate::rowmap::{id_at, optional_id_at, timestamp_at};

/// 统一列顺序。
const COLUMNS: &str =
    "id, note_id, version, parent_revision_id, created_at_ms, device_id, operation";

/// 从一行映射出 [`Revision`]（错误类型为 `rusqlite::Error`，见 `rowmap` 模块说明）。
fn map_row(row: &Row<'_>) -> rusqlite::Result<Revision> {
    Ok(Revision {
        id: id_at(row, 0, "revision")?,
        note_id: id_at(row, 1, "revision")?,
        version: row.get(2)?,
        parent_revision_id: optional_id_at(row, 3, "revision")?,
        created_at_ms: timestamp_at(row, 4)?.as_millis(),
        device_id: row.get(5)?,
        operation: row.get(6)?,
    })
}

/// 追加一条修订记录。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn insert(connection: &Connection, revision: &Revision) -> Result<(), DbError> {
    connection.execute(
        "INSERT INTO revisions (id, note_id, version, parent_revision_id, created_at_ms,
                                device_id, operation)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            revision.id.as_bytes(),
            revision.note_id.as_bytes(),
            revision.version,
            revision
                .parent_revision_id
                .as_ref()
                .map(|id| id.as_bytes().to_vec()),
            revision.created_at_ms,
            revision.device_id,
            revision.operation,
        ],
    )?;
    Ok(())
}

/// 按标识读取。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn get(connection: &Connection, id: &Id) -> Result<Option<Revision>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM revisions WHERE id = ?1");
    connection
        .query_row(&sql, params![id.as_bytes()], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 列出某篇笔记的修订，按版本倒序（最新在前）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_for_note(
    connection: &Connection,
    note_id: &Id,
    limit: u32,
) -> Result<Vec<Revision>, DbError> {
    let sql = format!(
        "SELECT {COLUMNS} FROM revisions WHERE note_id = ?1 ORDER BY version DESC LIMIT ?2"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![note_id.as_bytes(), i64::from(limit)], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 取某篇笔记当前最新的修订。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn latest_for_note(connection: &Connection, note_id: &Id) -> Result<Option<Revision>, DbError> {
    let sql =
        format!("SELECT {COLUMNS} FROM revisions WHERE note_id = ?1 ORDER BY version DESC LIMIT 1");
    connection
        .query_row(&sql, params![note_id.as_bytes()], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 统计某篇笔记的修订数量。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn count_for_note(connection: &Connection, note_id: &Id) -> Result<i64, DbError> {
    let total: i64 = connection.query_row(
        "SELECT COUNT(*) FROM revisions WHERE note_id = ?1",
        params![note_id.as_bytes()],
        |row| row.get(0),
    )?;
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;
    use nested_model::Note;

    const NOW: i64 = 1_700_000_000_000;

    fn note(connection: &Connection) -> Id {
        let note = Note::new(None, "修订测试", NOW).expect("valid");
        crate::repositories::notes::insert(connection, &note).expect("insert");
        note.id
    }

    #[test]
    fn revisions_form_a_chain() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);

        let first = Revision::new(note_id, 1, None, "device-a", "note.create", NOW);
        insert(&guard, &first).expect("first");
        let second = Revision::new(
            note_id,
            2,
            Some(first.id),
            "device-a",
            "note.update",
            NOW + 1,
        );
        insert(&guard, &second).expect("second");

        let latest = latest_for_note(&guard, &note_id)
            .expect("latest")
            .expect("exists");
        assert_eq!(latest.version, 2);
        assert_eq!(latest.parent_revision_id, Some(first.id));

        let history = list_for_note(&guard, &note_id, 10).expect("history");
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].version, 2, "最新修订排在最前");
        assert_eq!(count_for_note(&guard, &note_id).expect("count"), 2);
    }

    #[test]
    fn limit_is_respected() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        for version in 1..=5 {
            insert(
                &guard,
                &Revision::new(
                    note_id,
                    version,
                    None,
                    "device-a",
                    "note.update",
                    NOW + version,
                ),
            )
            .expect("insert");
        }
        assert_eq!(list_for_note(&guard, &note_id, 2).expect("list").len(), 2);
        assert_eq!(count_for_note(&guard, &note_id).expect("count"), 5);
    }

    #[test]
    fn latest_for_note_without_history_is_none() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        assert!(
            latest_for_note(&guard, &note(&guard))
                .expect("latest")
                .is_none()
        );
    }

    #[test]
    fn get_missing_is_none() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        assert!(get(&guard, &Id::new()).expect("get").is_none());
    }
}
