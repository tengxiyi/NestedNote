//! 同步操作队列仓储。
//!
//! 本地优先的关键机制（铁律 T3 / T6）：**任何**本地写操作都在**同一个事务**里
//! 往这里塞一条待推送记录，网络层稍后按序消费。这样"离线也能用"不是靠 UI 兜底，
//! 而是由数据层保证。

use nested_model::Id;
use rusqlite::{Connection, params};

use crate::DbError;
use crate::rowmap::id_at;
use crate::rowmap::optional_timestamp_at;
use crate::rowmap::timestamp_at;

/// 一条待同步操作。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncOperation {
    /// 操作标识。
    pub id: Id,
    /// 关联笔记。
    pub note_id: Option<Id>,
    /// 产生该操作的设备。
    pub device_id: String,
    /// 操作类型，如 `"note.update"`。
    pub operation: String,
    /// 变更负载（可选，JSON 字节）。
    pub payload: Option<Vec<u8>>,
    /// 入队时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 推送成功时间；`None` 表示仍待推送。
    pub pushed_at_ms: Option<i64>,
}

/// 统一列顺序。
const COLUMNS: &str = "id, note_id, device_id, operation, payload, created_at_ms, pushed_at_ms";

/// 从一行映射出 [`SyncOperation`]（错误类型为 `rusqlite::Error`，见 `rowmap` 模块说明）。
fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SyncOperation> {
    Ok(SyncOperation {
        id: id_at(row, 0, "sync_operation")?,
        note_id: crate::rowmap::optional_id_at(row, 1, "sync_operation")?,
        device_id: row.get(2)?,
        operation: row.get(3)?,
        payload: row.get(4)?,
        created_at_ms: timestamp_at(row, 5)?.as_millis(),
        pushed_at_ms: optional_timestamp_at(row, 6)?.map(|ts| ts.as_millis()),
    })
}

/// 入队一条操作。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn enqueue(
    connection: &Connection,
    note_id: &Id,
    device_id: &str,
    operation: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    enqueue_with_payload(connection, note_id, device_id, operation, None, at_ms)
}

/// 入队一条带负载的操作。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn enqueue_with_payload(
    connection: &Connection,
    note_id: &Id,
    device_id: &str,
    operation: &str,
    payload: Option<&[u8]>,
    at_ms: i64,
) -> Result<(), DbError> {
    connection.execute(
        "INSERT INTO sync_operations (id, note_id, device_id, operation, payload,
                                      created_at_ms, pushed_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)",
        params![
            Id::new().as_bytes(),
            note_id.as_bytes(),
            device_id,
            operation,
            payload,
            at_ms,
        ],
    )?;
    Ok(())
}

/// 列出尚未推送的操作，按入队顺序（同步必须按序应用）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_pending(connection: &Connection, limit: u32) -> Result<Vec<SyncOperation>, DbError> {
    let sql = format!(
        "SELECT {COLUMNS} FROM sync_operations
         WHERE pushed_at_ms IS NULL
         ORDER BY created_at_ms ASC, rowid ASC
         LIMIT ?1"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![i64::from(limit)], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 标记操作已推送。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn mark_pushed(connection: &Connection, id: &Id, at_ms: i64) -> Result<(), DbError> {
    connection.execute(
        "UPDATE sync_operations SET pushed_at_ms = ?2 WHERE id = ?1",
        params![id.as_bytes(), at_ms],
    )?;
    Ok(())
}

/// 统计待推送数量（用于同步状态 UI）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn pending_count(connection: &Connection) -> Result<i64, DbError> {
    let total: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sync_operations WHERE pushed_at_ms IS NULL",
        [],
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
        let note = Note::new(None, "同步队列", NOW).expect("valid");
        crate::repositories::notes::insert(connection, &note).expect("insert");
        note.id
    }

    #[test]
    fn enqueue_then_list_pending_in_order() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);

        enqueue(&guard, &note_id, "device-a", "note.create", NOW).expect("1");
        enqueue(&guard, &note_id, "device-a", "note.update", NOW + 1).expect("2");

        let pending = list_pending(&guard, 10).expect("pending");
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].operation, "note.create");
        assert_eq!(pending[1].operation, "note.update");
        assert_eq!(pending_count(&guard).expect("count"), 2);
    }

    #[test]
    fn mark_pushed_removes_from_pending() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        enqueue(&guard, &note_id, "device-a", "note.update", NOW).expect("enqueue");

        let first = list_pending(&guard, 10).expect("pending").remove(0);
        mark_pushed(&guard, &first.id, NOW + 5).expect("push");

        assert!(list_pending(&guard, 10).expect("pending").is_empty());
        assert_eq!(pending_count(&guard).expect("count"), 0);
    }

    #[test]
    fn payload_is_preserved() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        let payload = br#"{"title":"x"}"#;
        enqueue_with_payload(
            &guard,
            &note_id,
            "device-a",
            "note.update",
            Some(payload),
            NOW,
        )
        .expect("enqueue");

        let pending = list_pending(&guard, 1).expect("pending");
        assert_eq!(pending[0].payload.as_deref(), Some(payload.as_slice()));
    }

    #[test]
    fn limit_is_respected() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        for index in 0..5 {
            enqueue(&guard, &note_id, "device-a", "note.update", NOW + index).expect("enqueue");
        }
        assert_eq!(list_pending(&guard, 2).expect("pending").len(), 2);
        assert_eq!(pending_count(&guard).expect("count"), 5);
    }
}
