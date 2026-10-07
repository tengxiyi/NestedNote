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

// ---------------------------------------------------------------- 内容快照
//
// 设计依据：`docs/adr/0001-修订内容用完整快照.md`
//
// `revisions` 原本只有元数据，因此"修订对比"没有内容可对比。
// 迁移 0003 增加了 `revision_documents`，每个修订保存一份**完整快照**
// （而不是差量）。取舍见 ADR，这里只强调两条实现约束：
//
// 1. 快照必须与 `revisions` 行在**同一事务**里写入（铁律 D1）；
// 2. 读取一律用 `LEFT JOIN` / 可选返回——**允许缺失**。
//    迁移 0003 之前的历史修订没有快照，这必须被如实表达，
//    而**不能**用当前内容回填（那是在伪造审计材料）。

/// 追加一条修订的**内容快照**。
///
/// 调用方必须在写 `revisions` 行的**同一事务**里调用它（铁律 D1）：
/// 只有元数据没有内容的修订，与只有内容没有元数据的快照，都是坏数据。
///
/// # Errors
///
/// - 修订不存在（外键失败）或写入失败 → [`DbError`]
pub fn insert_document(
    connection: &Connection,
    revision_id: &Id,
    content: &[u8],
) -> Result<(), DbError> {
    connection.execute(
        "INSERT INTO revision_documents (revision_id, content) VALUES (?1, ?2)",
        params![revision_id.as_bytes(), content],
    )?;
    Ok(())
}

/// 读取一条修订的内容快照。
///
/// 返回 `Ok(None)` 表示**该修订没有快照**（迁移 0003 之前的历史）——
/// 这与"快照是空的"是两回事，调用方必须区分：
/// 前者应显示"此版本没有内容快照"，后者才该显示空文档。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn get_document(connection: &Connection, revision_id: &Id) -> Result<Option<Vec<u8>>, DbError> {
    connection
        .query_row(
            "SELECT content FROM revision_documents WHERE revision_id = ?1",
            params![revision_id.as_bytes()],
            |row| row.get::<_, Vec<u8>>(0),
        )
        .optional()
        .map_err(DbError::from)
}

/// 统计某篇笔记有多少条修订**带**内容快照。
///
/// 界面用它说明"历史中有多少版本可以对比"，避免用户以为是功能坏了。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn count_documents_for_note(connection: &Connection, note_id: &Id) -> Result<i64, DbError> {
    let total: i64 = connection.query_row(
        "SELECT COUNT(*) FROM revision_documents d
           JOIN revisions r ON r.id = d.revision_id
          WHERE r.note_id = ?1",
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

    // ------------------------------------------------------------ 内容快照

    /// 建一条修订并写入快照，返回修订 id。
    fn revision_with_snapshot(
        connection: &Connection,
        note_id: Id,
        version: i64,
        content: &[u8],
    ) -> Id {
        let revision = Revision::new(note_id, version, None, "device-a", "note.update", NOW);
        insert(connection, &revision).expect("insert revision");
        insert_document(connection, &revision.id, content).expect("insert snapshot");
        revision.id
    }

    #[test]
    fn snapshot_roundtrips() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        let id = revision_with_snapshot(&guard, note_id, 1, b"{\"blocks\":[]}");

        assert_eq!(
            get_document(&guard, &id).expect("get"),
            Some(b"{\"blocks\":[]}".to_vec())
        );
        assert_eq!(
            count_documents_for_note(&guard, &note_id).expect("count"),
            1
        );
    }

    #[test]
    fn snapshot_is_a_full_copy_not_a_shared_reference() {
        // 快照的语义是"这一刻的完整内容"。若它与 documents 共享引用，
        // 之后的编辑会**改掉历史**——审计材料就失去意义了。
        // 这里用两次不同的内容直接验证"各存各的"。
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        let v1 = revision_with_snapshot(&guard, note_id, 1, b"first");
        let v2 = revision_with_snapshot(&guard, note_id, 2, b"second");

        assert_eq!(
            get_document(&guard, &v1).expect("v1"),
            Some(b"first".to_vec())
        );
        assert_eq!(
            get_document(&guard, &v2).expect("v2"),
            Some(b"second".to_vec()),
            "后写的快照不得影响先前的"
        );
    }

    #[test]
    fn missing_snapshot_is_none_not_empty() {
        // 迁移 0003 之前的历史修订没有快照。
        // 这个区别很重要：返回空 Vec 会让界面显示"这一版是空的"，
        // 用户会以为数据损坏，而实际上只是"那条记录早于快照功能"。
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        let revision = Revision::new(note_id, 1, None, "device-a", "note.create", NOW);
        insert(&guard, &revision).expect("insert");

        assert_eq!(
            get_document(&guard, &revision.id).expect("get"),
            None,
            "没有快照必须是 None，不能退化成空内容"
        );
        assert_eq!(
            count_documents_for_note(&guard, &note_id).expect("count"),
            0
        );
    }

    #[test]
    fn snapshot_for_missing_revision_fails_on_foreign_key() {
        // 快照不能挂在不存在的修订上——否则它是永远查不到的垃圾
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        assert!(
            insert_document(&guard, &Id::new(), b"orphan").is_err(),
            "外键必须拦住指向不存在修订的快照"
        );
    }
}
