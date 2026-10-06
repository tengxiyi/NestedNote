//! 标签仓储。

use nested_model::{Id, Tag};
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::DbError;
use crate::rowmap::{id_at, optional_timestamp_at, timestamp_at};

/// 统一列顺序。
const COLUMNS: &str = "id, name, created_at_ms, deleted_at_ms";

/// 从一行映射出 [`Tag`]（错误类型为 `rusqlite::Error`，见 `rowmap` 模块说明）。
fn map_row(row: &Row<'_>) -> rusqlite::Result<Tag> {
    Ok(Tag {
        id: id_at(row, 0, "tag")?,
        name: row.get(1)?,
        created_at_ms: timestamp_at(row, 2)?.as_millis(),
        deleted_at_ms: optional_timestamp_at(row, 3)?.map(|ts| ts.as_millis()),
    })
}

/// 插入标签。
///
/// # Errors
///
/// 名称与现有标签重复（忽略大小写）时返回 [`DbError::Conflict`]。
pub fn insert(connection: &Connection, tag: &Tag) -> Result<(), DbError> {
    connection
        .execute(
            "INSERT INTO tags (id, name, created_at_ms, deleted_at_ms) VALUES (?1, ?2, ?3, ?4)",
            params![
                tag.id.as_bytes(),
                tag.name,
                tag.created_at_ms,
                tag.deleted_at_ms
            ],
        )
        .map_err(|error| match error {
            rusqlite::Error::SqliteFailure(inner, _)
                if inner.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                DbError::Conflict { entity: "tag" }
            }
            other => DbError::Sqlite(other),
        })?;
    Ok(())
}

/// 按名称查找（忽略大小写）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn find_by_name(connection: &Connection, name: &str) -> Result<Option<Tag>, DbError> {
    let sql = format!(
        "SELECT {COLUMNS} FROM tags WHERE name = ?1 COLLATE NOCASE AND deleted_at_ms IS NULL"
    );
    connection
        .query_row(&sql, params![name], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 按标识读取。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn get(connection: &Connection, id: &Id) -> Result<Option<Tag>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM tags WHERE id = ?1");
    connection
        .query_row(&sql, params![id.as_bytes()], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 列出全部未删除标签。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_all(connection: &Connection) -> Result<Vec<Tag>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM tags WHERE deleted_at_ms IS NULL ORDER BY name ASC");
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map([], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 给笔记打标签（重复打标签是幂等的）。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn attach(
    connection: &Connection,
    note_id: &Id,
    tag_id: &Id,
    at_ms: i64,
) -> Result<(), DbError> {
    connection.execute(
        "INSERT INTO note_tags (note_id, tag_id, tagged_at_ms) VALUES (?1, ?2, ?3)
         ON CONFLICT (note_id, tag_id) DO NOTHING",
        params![note_id.as_bytes(), tag_id.as_bytes(), at_ms],
    )?;
    Ok(())
}

/// 取消标签。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn detach(connection: &Connection, note_id: &Id, tag_id: &Id) -> Result<(), DbError> {
    connection.execute(
        "DELETE FROM note_tags WHERE note_id = ?1 AND tag_id = ?2",
        params![note_id.as_bytes(), tag_id.as_bytes()],
    )?;
    Ok(())
}

/// 覆盖设置一篇笔记的标签集合（在调用方的事务内执行）。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn set_note_tags(
    connection: &Connection,
    note_id: &Id,
    tag_ids: &[Id],
    at_ms: i64,
) -> Result<(), DbError> {
    connection.execute(
        "DELETE FROM note_tags WHERE note_id = ?1",
        params![note_id.as_bytes()],
    )?;
    for tag_id in tag_ids {
        attach(connection, note_id, tag_id, at_ms)?;
    }
    Ok(())
}

/// 列出某篇笔记的标签。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_for_note(connection: &Connection, note_id: &Id) -> Result<Vec<Tag>, DbError> {
    let columns = COLUMNS
        .split(", ")
        .map(|column| format!("t.{column}"))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT {columns} FROM tags t
         JOIN note_tags nt ON nt.tag_id = t.id
         WHERE nt.note_id = ?1 AND t.deleted_at_ms IS NULL
         ORDER BY t.name ASC"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![note_id.as_bytes()], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 软删除标签。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn soft_delete(connection: &Connection, id: &Id, at_ms: i64) -> Result<(), DbError> {
    let changed = connection.execute(
        "UPDATE tags SET deleted_at_ms = ?2 WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "tag" });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;

    const NOW: i64 = 1_700_000_000_000;

    fn tag(name: &str) -> Tag {
        Tag::new(name, NOW).expect("valid tag")
    }

    #[test]
    fn insert_and_find_case_insensitively() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let original = tag("Work");
        insert(&guard, &original).expect("insert");
        let found = find_by_name(&guard, "work").expect("find").expect("exists");
        assert_eq!(found.id, original.id);
    }

    #[test]
    fn duplicate_name_is_a_conflict_not_a_panic() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        insert(&guard, &tag("重复")).expect("first");
        let err = insert(&guard, &tag("重复")).expect_err("duplicate must fail");
        assert!(matches!(err, DbError::Conflict { entity: "tag" }));
    }

    #[test]
    fn chinese_tags_are_supported() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        insert(&guard, &tag("灵感")).expect("insert");
        insert(&guard, &tag("工作")).expect("insert");
        let names: Vec<String> = list_all(&guard)
            .expect("list")
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names.len(), 2);
    }

    #[test]
    fn attach_is_idempotent_and_detach_removes() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let one = tag("一");
        insert(&guard, &one).expect("insert tag");

        attach(&guard, &note, &one.id, NOW).expect("attach");
        attach(&guard, &note, &one.id, NOW).expect("attach again is fine");
        assert_eq!(list_for_note(&guard, &note).expect("list").len(), 1);

        detach(&guard, &note, &one.id).expect("detach");
        assert!(list_for_note(&guard, &note).expect("list").is_empty());
    }

    #[test]
    fn set_note_tags_replaces_previous_set() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let first = tag("旧");
        let second = tag("新");
        insert(&guard, &first).expect("insert");
        insert(&guard, &second).expect("insert");

        set_note_tags(&guard, &note, &[first.id], NOW).expect("set");
        assert_eq!(list_for_note(&guard, &note).expect("list").len(), 1);

        set_note_tags(&guard, &note, &[second.id], NOW).expect("replace");
        let current = list_for_note(&guard, &note).expect("list");
        assert_eq!(current.len(), 1);
        assert_eq!(current[0].name, "新");
    }

    #[test]
    fn soft_deleted_tag_disappears_from_note_tags() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let item = tag("会被删");
        insert(&guard, &item).expect("insert");
        attach(&guard, &note, &item.id, NOW).expect("attach");

        soft_delete(&guard, &item.id, NOW + 1).expect("delete");
        assert!(list_for_note(&guard, &note).expect("list").is_empty());
        assert!(list_all(&guard).expect("list").is_empty());
    }

    #[test]
    fn soft_delete_missing_is_not_found() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        assert!(matches!(
            soft_delete(&guard, &Id::new(), NOW).expect_err("missing"),
            DbError::NotFound { entity: "tag" }
        ));
    }

    /// 建一篇最小笔记，返回其 id（标签关系统需要外键目标存在）。
    fn insert_note(connection: &Connection) -> Id {
        let note = nested_model::Note::new(None, "标签测试", NOW).expect("valid");
        crate::repositories::notes::insert(connection, &note).expect("insert note");
        note.id
    }
}
