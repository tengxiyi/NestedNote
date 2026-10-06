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
/// 插入一个标签（同一事务入队，铁律 T3）。
///
/// 名称与现有标签重复（忽略大小写）时返回 [`DbError::Conflict`]。
///
/// # Errors
///
/// 重名或写入失败时返回 [`DbError`]。
pub fn insert(connection: &mut Connection, tag: &Tag, device_id: &str) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    insert_in_transaction(&transaction, tag)?;
    crate::repositories::sync_operations::enqueue(
        &transaction,
        &tag.id,
        device_id,
        "tag.create",
        tag.created_at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 在给定事务内插入标签（供其它事务复用，不自行开关事务）。
///
/// # Errors
///
/// 重名或写入失败时返回 [`DbError`]。
pub fn insert_in_transaction(connection: &Connection, tag: &Tag) -> Result<(), DbError> {
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

/// 覆盖设置一篇笔记的标签集合（同一事务入队，铁律 T3）。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn set_note_tags(
    connection: &mut Connection,
    note_id: &Id,
    tag_ids: &[Id],
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    transaction.execute(
        "DELETE FROM note_tags WHERE note_id = ?1",
        params![note_id.as_bytes()],
    )?;
    for tag_id in tag_ids {
        attach(&transaction, note_id, tag_id, at_ms)?;
    }
    // 标签是笔记属性的一部分，因此以 note 为实体入队
    crate::repositories::sync_operations::enqueue(
        &transaction,
        note_id,
        device_id,
        "note.tag",
        at_ms,
    )?;
    transaction.commit()?;
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
/// 软删除标签（同一事务入队，铁律 T3 / T7）。
///
/// ## 已知取舍：删除的标签名暂时无法复用
///
/// `idx_tags_name_unique` 是 `name COLLATE NOCASE` 上的唯一索引，且**不含**
/// `deleted_at_ms`，因此软删一个标签后再建同名标签会被判为重名
/// （TECH-DEBT(#13)）。附件表用的是"命中墓碑则复活"的策略，标签尚未对齐。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn soft_delete(
    connection: &mut Connection,
    id: &Id,
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    let changed = transaction.execute(
        "UPDATE tags SET deleted_at_ms = ?2 WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "tag" });
    }
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "tag.delete",
        at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;

    const NOW: i64 = 1_700_000_000_000;
    const DEVICE: &str = "device-test";

    fn tag(name: &str) -> Tag {
        Tag::new(name, NOW).expect("valid tag")
    }

    #[test]
    fn insert_and_find_case_insensitively() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let original = tag("Work");
        insert(&mut guard, &original, DEVICE).expect("insert");
        let found = find_by_name(&guard, "work").expect("find").expect("exists");
        assert_eq!(found.id, original.id);
    }

    #[test]
    fn duplicate_name_is_a_conflict_not_a_panic() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        insert(&mut guard, &tag("重复"), DEVICE).expect("first");
        let err = insert(&mut guard, &tag("重复"), DEVICE).expect_err("duplicate must fail");
        assert!(matches!(err, DbError::Conflict { entity: "tag" }));
    }

    #[test]
    fn chinese_tags_are_supported() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        insert(&mut guard, &tag("灵感"), DEVICE).expect("insert");
        insert(&mut guard, &tag("工作"), DEVICE).expect("insert");
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
        let mut guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let one = tag("一");
        insert(&mut guard, &one, DEVICE).expect("insert tag");

        attach(&guard, &note, &one.id, NOW).expect("attach");
        attach(&guard, &note, &one.id, NOW).expect("attach again is fine");
        assert_eq!(list_for_note(&guard, &note).expect("list").len(), 1);

        detach(&guard, &note, &one.id).expect("detach");
        assert!(list_for_note(&guard, &note).expect("list").is_empty());
    }

    #[test]
    fn set_note_tags_replaces_previous_set() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let first = tag("旧");
        let second = tag("新");
        insert(&mut guard, &first, DEVICE).expect("insert");
        insert(&mut guard, &second, DEVICE).expect("insert");

        set_note_tags(&mut guard, &note, &[first.id], DEVICE, NOW).expect("set");
        assert_eq!(list_for_note(&guard, &note).expect("list").len(), 1);

        set_note_tags(&mut guard, &note, &[second.id], DEVICE, NOW).expect("replace");
        let current = list_for_note(&guard, &note).expect("list");
        assert_eq!(current.len(), 1);
        assert_eq!(current[0].name, "新");
    }

    #[test]
    fn soft_deleted_tag_disappears_from_note_tags() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let item = tag("会被删");
        insert(&mut guard, &item, DEVICE).expect("insert");
        attach(&guard, &note, &item.id, NOW).expect("attach");

        soft_delete(&mut guard, &item.id, DEVICE, NOW + 1).expect("delete");
        assert!(list_for_note(&guard, &note).expect("list").is_empty());
        assert!(list_all(&guard).expect("list").is_empty());
    }

    #[test]
    fn soft_delete_missing_is_not_found() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        assert!(matches!(
            soft_delete(&mut guard, &Id::new(), DEVICE, NOW).expect_err("missing"),
            DbError::NotFound { entity: "tag" }
        ));
    }

    #[test]
    fn tag_mutations_enqueue_sync_operations() {
        // 技术债 #12：标签变更此前完全不入队。这里锁住"创建 + 删除"都会入队，
        // 否则标签在多设备之间永远不会同步。
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");

        let item = tag("要同步的");
        insert(&mut guard, &item, DEVICE).expect("insert tag");
        assert_eq!(
            pending_count(&guard).expect("pending"),
            1,
            "tag.create 应入队"
        );

        soft_delete(&mut guard, &item.id, DEVICE, NOW + 1).expect("delete tag");
        assert_eq!(
            pending_count(&guard).expect("pending"),
            2,
            "tag.delete 应入队"
        );
    }

    #[test]
    fn setting_note_tags_enqueues_a_note_level_operation() {
        // 标签是笔记的属性，因此以 note 为实体入队（而不是每个标签一条）
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let note = insert_note(&guard);
        let one = tag("甲");
        insert(&mut guard, &one, DEVICE).expect("insert tag");

        set_note_tags(&mut guard, &note, &[one.id], DEVICE, NOW + 1).expect("set tags");

        let mut statement = guard
            .prepare("SELECT entity_id FROM sync_operations WHERE operation = 'note.tag'")
            .expect("prepare");
        let rows: Vec<Vec<u8>> = statement
            .query_map([], |row| row.get(0))
            .expect("query")
            .collect::<Result<_, _>>()
            .expect("collect");
        assert_eq!(rows.len(), 1, "设置标签应产生一条 note.tag 操作");
        assert_eq!(rows[0], note.as_bytes().to_vec(), "实体应为该笔记");
    }

    /// 统计待推送队列长度（测试辅助）。
    fn pending_count(connection: &Connection) -> Result<i64, DbError> {
        connection
            .query_row(
                "SELECT COUNT(*) FROM sync_operations WHERE pushed_at_ms IS NULL",
                [],
                |row| row.get(0),
            )
            .map_err(DbError::from)
    }

    /// 建一篇最小笔记，返回其 id（标签关系统需要外键目标存在）。
    fn insert_note(connection: &Connection) -> Id {
        let note = nested_model::Note::new(None, "标签测试", NOW).expect("valid");
        crate::repositories::notes::insert(connection, &note).expect("insert note");
        note.id
    }
}
