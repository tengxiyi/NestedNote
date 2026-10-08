// SPDX-License-Identifier: AGPL-3.0-or-later
//! 活动日志的存储（迁移 `0004_activity_log.sql`）。
//!
//! ## 定位
//!
//! 记录**维护/破坏性**操作（回收站清理、附件 GC、完整性核对），
//! 兑现铁律 T1 修订说明里的"可追溯"承诺。笔记级变更由 `revisions`
//! 覆盖，这里刻意不重复。
//!
//! ## 只追加
//!
//! 事件行**没有**更新或删除的路径——审计记录被改动比缺失更糟。
//! 接口只有 [`append`] 与 [`list_recent`]。

use nested_model::Id;
use rusqlite::{Connection, Row, params};

use crate::DbError;
use crate::rowmap::{id_at, timestamp_at};

/// 一条活动记录。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityEvent {
    /// 事件标识（UUIDv7）。
    pub event_id: Id,
    /// 发生时间（UTC 毫秒）。
    pub at_ms: i64,
    /// 事件类型，如 `trash.purge` / `attachments.gc` / `integrity.check`。
    pub kind: String,
    /// 给人看的说明（含关键数字），界面直接展示。
    pub detail: String,
}

/// 追加一条活动记录。
///
/// # Errors
///
/// 写入失败 → [`DbError`]。调用方（core）决定失败如何呈现——
/// 见 `record_activity` 的说明：主操作已成功时日志失败**不能**让
/// 用户以为操作失败了，但必须留痕到日志框架。
pub fn append(
    connection: &Connection,
    event_id: &Id,
    at_ms: i64,
    kind: &str,
    detail: &str,
) -> Result<(), DbError> {
    connection
        .execute(
            "INSERT INTO activity_events (event_id, at_ms, kind, detail)
             VALUES (?1, ?2, ?3, ?4)",
            params![crate::rowmap::id_to_blob(event_id), at_ms, kind, detail],
        )
        .map(|_| ())
        .map_err(DbError::from)
}

/// 按时间倒序列出最近的记录。
///
/// # Errors
///
/// 查询失败 → [`DbError`]。
pub fn list_recent(connection: &Connection, limit: u32) -> Result<Vec<ActivityEvent>, DbError> {
    let effective = if limit == 0 { 200 } else { limit };
    let mut statement = connection
        .prepare(
            "SELECT event_id, at_ms, kind, detail
             FROM activity_events
             ORDER BY at_ms DESC
             LIMIT ?1",
        )
        .map_err(DbError::from)?;
    let map = |row: &Row<'_>| -> rusqlite::Result<ActivityEvent> {
        Ok(ActivityEvent {
            event_id: id_at(row, 0, "activity_event")?,
            at_ms: timestamp_at(row, 1)?.as_millis(),
            kind: row.get(2)?,
            detail: row.get(3)?,
        })
    };
    let rows = statement
        .query_map(params![i64::from(effective)], map)
        .map_err(DbError::from)?;
    let mut events = Vec::new();
    for row in rows {
        events.push(row.map_err(DbError::from)?);
    }
    Ok(events)
}
