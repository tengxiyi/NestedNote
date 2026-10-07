//! 附件仓储。
//!
//! **文件本体绝不入库**（铁律 T8）：本模块只处理元数据与引用关系，
//! 字节流由 `nested-attachment` 写入内容寻址存储。

use nested_model::{Attachment, Id};
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::DbError;
use crate::rowmap::{corrupt, i64_to_u64, id_at, optional_timestamp_at, timestamp_at, u64_to_i64};

/// 统一列顺序。
const COLUMNS: &str = "id, sha256, mime_type, size_bytes, filename, created_at_ms, deleted_at_ms";

/// 从一行映射出 [`Attachment`]（错误类型为 `rusqlite::Error`，见 `rowmap` 模块说明）。
fn map_row(row: &Row<'_>) -> rusqlite::Result<Attachment> {
    Ok(Attachment {
        id: id_at(row, 0, "attachment")?,
        sha256: row.get(1)?,
        mime_type: row.get(2)?,
        size_bytes: i64_to_u64(row.get(3)?, "attachment").map_err(|_| corrupt("attachment"))?,
        filename: row.get(4)?,
        created_at_ms: timestamp_at(row, 5)?.as_millis(),
        deleted_at_ms: optional_timestamp_at(row, 6)?.map(|ts| ts.as_millis()),
    })
}

/// 插入或复用一条附件元数据。
///
/// 相同内容（SHA-256 相同）**只保留一条记录**——这正是内容寻址带来的自动去重
/// （技术文档 §9）。已存在时刷新文件名并清除墓碑，返回既有记录的标识。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn upsert(connection: &Connection, attachment: &Attachment) -> Result<Id, DbError> {
    connection.execute(
        "INSERT INTO attachments (id, sha256, mime_type, size_bytes, filename, ref_count,
                                  created_at_ms, deleted_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, NULL)
         ON CONFLICT (sha256) DO UPDATE SET
             filename = excluded.filename,
             mime_type = excluded.mime_type,
             deleted_at_ms = NULL",
        params![
            attachment.id.as_bytes(),
            attachment.sha256,
            attachment.mime_type,
            u64_to_i64(attachment.size_bytes, "attachment")?,
            attachment.filename,
            attachment.created_at_ms,
        ],
    )?;

    let id: Vec<u8> = connection.query_row(
        "SELECT id FROM attachments WHERE sha256 = ?1",
        params![attachment.sha256],
        |row| row.get(0),
    )?;
    Id::from_slice(&id).map_err(|_| DbError::Corrupt {
        entity: "attachment",
    })
}

/// 按内容哈希查找。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn find_by_sha256(
    connection: &Connection,
    sha256: &str,
) -> Result<Option<Attachment>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM attachments WHERE sha256 = ?1");
    connection
        .query_row(&sql, params![sha256], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 按标识读取。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn get(connection: &Connection, id: &Id) -> Result<Option<Attachment>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM attachments WHERE id = ?1");
    connection
        .query_row(&sql, params![id.as_bytes()], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 重算某附件的引用计数（由笔记 ↔ 附件关系表推导，不维护冗余计数器）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn refresh_ref_count(connection: &Connection, id: &Id) -> Result<i64, DbError> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM note_attachments WHERE attachment_id = ?1",
        params![id.as_bytes()],
        |row| row.get(0),
    )?;
    connection.execute(
        "UPDATE attachments SET ref_count = ?2 WHERE id = ?1",
        params![id.as_bytes(), count],
    )?;
    Ok(count)
}

/// 把笔记的附件引用同步为给定的集合（新增缺失、移除多余、刷新计数）。
///
/// 由 `notes` 的写入路径调用，**必须**在调用方的事务内（铁律 D1）。
///
/// # Errors
///
/// 任一步失败时返回 [`DbError`]，由调用方回滚。
pub fn sync_note_links(
    connection: &Connection,
    note_id: &Id,
    attachment_ids: &[Id],
    at_ms: i64,
) -> Result<(), DbError> {
    let existing: Vec<Id> = {
        let mut statement =
            connection.prepare("SELECT attachment_id FROM note_attachments WHERE note_id = ?1")?;
        let rows = statement.query_map(params![note_id.as_bytes()], |row| {
            let raw: Vec<u8> = row.get(0)?;
            Ok(raw)
        })?;
        let mut ids = Vec::new();
        for raw in rows {
            let raw = raw?;
            ids.push(Id::from_slice(&raw).map_err(|_| DbError::Corrupt {
                entity: "attachment",
            })?);
        }
        ids
    };

    let mut touched: Vec<Id> = Vec::new();

    for id in attachment_ids {
        if !existing.contains(id) {
            connection.execute(
                "INSERT INTO note_attachments (note_id, attachment_id, linked_at_ms)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT (note_id, attachment_id) DO NOTHING",
                params![note_id.as_bytes(), id.as_bytes(), at_ms],
            )?;
        }
        touched.push(*id);
    }

    for id in &existing {
        if !attachment_ids.contains(id) {
            connection.execute(
                "DELETE FROM note_attachments WHERE note_id = ?1 AND attachment_id = ?2",
                params![note_id.as_bytes(), id.as_bytes()],
            )?;
            touched.push(*id);
        }
    }

    for id in touched {
        refresh_ref_count(connection, &id)?;
    }
    Ok(())
}

/// 给"附件元数据变更"补上同步入队（技术债 #22）。
///
/// ## 为什么附件也需要入队
///
/// 铁律 T3 要求**任何**本地写操作都入队。附件元数据（文件名、MIME、大小、
/// 内容哈希）是笔记的一部分：如果它不同步，其它设备上的笔记就会缺附件。
///
/// 字节本体**不走**这条队列——它由内容寻址存储负责，
/// 同步时按哈希拉取即可（这也是内容寻址的收益之一）。
///
/// ## 与 `notes` 入队的关系
///
/// `sync_note_links` 建立笔记 ↔ 附件的关联时，关联本身会随笔记内容一起同步
/// （文档里记录了附件 id）。因此这里**只**为附件元数据自身的创建/变更入队，
/// 不重复为关联入队。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn enqueue_sync(
    connection: &Connection,
    attachment_id: &Id,
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    crate::repositories::sync_operations::enqueue(
        connection,
        attachment_id,
        device_id,
        "attachment.create",
        at_ms,
    )
}

/// 列出没有任何引用的附件（GC 候选，**不**在此物理删除，铁律 D2）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_unreferenced(connection: &Connection) -> Result<Vec<Attachment>, DbError> {
    let sql = format!(
        "SELECT {COLUMNS} FROM attachments
         WHERE ref_count <= 0
           AND NOT EXISTS (SELECT 1 FROM note_attachments na WHERE na.attachment_id = attachments.id)
         ORDER BY created_at_ms ASC"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map([], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 列出某篇笔记引用的附件。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list_for_note(connection: &Connection, note_id: &Id) -> Result<Vec<Attachment>, DbError> {
    let sql = "SELECT a.id, a.sha256, a.mime_type, a.size_bytes, a.filename, a.created_at_ms,
                a.deleted_at_ms
         FROM attachments a
         JOIN note_attachments na ON na.attachment_id = a.id
         WHERE na.note_id = ?1
         ORDER BY a.created_at_ms ASC"
        .to_string();
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![note_id.as_bytes()], map_row)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 统计附件总字节数（用于备份体积预估与配额展示）。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn total_bytes(connection: &Connection) -> Result<u64, DbError> {
    let total: i64 = connection.query_row(
        "SELECT COALESCE(SUM(size_bytes), 0) FROM attachments WHERE deleted_at_ms IS NULL",
        [],
        |row| row.get(0),
    )?;
    i64_to_u64(total, "attachment")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;
    use nested_model::{Block, Document, Note};

    const NOW: i64 = 1_700_000_000_000;

    fn hash(seed: char) -> String {
        seed.to_string().repeat(64)
    }

    fn attachment(seed: char, filename: &str) -> Attachment {
        Attachment::new(hash(seed), "image/png", 1024, filename, NOW).expect("valid")
    }

    fn note(connection: &Connection) -> Id {
        let note = Note::new(None, "附件测试", NOW).expect("valid");
        crate::repositories::notes::insert(connection, &note).expect("insert");
        note.id
    }

    #[test]
    fn same_content_is_deduplicated() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");

        let first = attachment('a', "cat.png");
        let id_first = upsert(&guard, &first).expect("first");
        // 同一内容、不同文件名：必须复用同一条记录
        let second =
            Attachment::new(hash('a'), "image/png", 1024, "cat-copy.png", NOW).expect("valid");
        let id_second = upsert(&guard, &second).expect("second");

        assert_eq!(id_first, id_second, "相同 SHA-256 必须去重为一条记录");
        let loaded = get(&guard, &id_first).expect("get").expect("exists");
        assert_eq!(loaded.filename, "cat-copy.png", "文件名应刷新为最新");
        let total: i64 = guard
            .query_row("SELECT COUNT(*) FROM attachments", [], |row| row.get(0))
            .expect("count");
        assert_eq!(total, 1);
    }

    #[test]
    fn ref_count_follows_references() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let first_note = note(&guard);
        let second_note = note(&guard);
        let item = attachment('b', "doc.pdf");
        let id = upsert(&guard, &item).expect("upsert");

        sync_note_links(&guard, &first_note, &[id], NOW).expect("link 1");
        assert_eq!(refresh_ref_count(&guard, &id).expect("count"), 1);
        assert!(list_unreferenced(&guard).expect("list").is_empty());

        sync_note_links(&guard, &second_note, &[id], NOW).expect("link 2");
        assert_eq!(refresh_ref_count(&guard, &id).expect("count"), 2);

        sync_note_links(&guard, &first_note, &[], NOW).expect("unlink 1");
        assert_eq!(refresh_ref_count(&guard, &id).expect("count"), 1);

        sync_note_links(&guard, &second_note, &[], NOW).expect("unlink 2");
        assert_eq!(refresh_ref_count(&guard, &id).expect("count"), 0);
        assert_eq!(
            list_unreferenced(&guard).expect("list").len(),
            1,
            "无引用后成为 GC 候选"
        );
    }

    #[test]
    fn sync_note_links_is_idempotent() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let note_id = note(&guard);
        let id = upsert(&guard, &attachment('c', "a.png")).expect("upsert");

        sync_note_links(&guard, &note_id, &[id], NOW).expect("first");
        sync_note_links(&guard, &note_id, &[id], NOW).expect("second");
        let links: i64 = guard
            .query_row("SELECT COUNT(*) FROM note_attachments", [], |row| {
                row.get(0)
            })
            .expect("count");
        assert_eq!(links, 1);
    }

    #[test]
    fn document_attachments_are_linked_through_note_write() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let item = attachment('d', "shot.png");
        let id = upsert(&guard, &item).expect("upsert");

        // 用嵌套结构引用附件，验证递归收集
        let document = Document::from_blocks(
            vec![Block::List {
                ordered: false,
                start: 1,
                items: vec![nested_model::ListItem {
                    text: "带图的项目".to_owned(),
                    children: vec![Block::Image {
                        attachment_id: id,
                        alt: None,
                        width: None,
                        height: None,
                    }],
                }],
            }],
            NOW,
        );
        let note_id = note(&guard);
        let note_row = crate::repositories::notes::get(&guard, &note_id)
            .expect("get")
            .expect("exists");
        crate::repositories::notes::save_with_document(
            &mut guard,
            &note_row,
            &document,
            "device-test",
            None,
        )
        .expect("save");

        let linked = list_for_note(&guard, &note_id).expect("list");
        assert_eq!(linked.len(), 1);
        assert_eq!(linked[0].id, id);
    }

    #[test]
    fn unreferenced_attachments_are_not_deleted_physically() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        upsert(&guard, &attachment('e', "orphan.png")).expect("upsert");

        let candidates = list_unreferenced(&guard).expect("list");
        assert_eq!(candidates.len(), 1);
        let total: i64 = guard
            .query_row("SELECT COUNT(*) FROM attachments", [], |row| row.get(0))
            .expect("count");
        assert_eq!(total, 1, "GC 候选不得被自动物理删除（铁律 D2）");
    }

    #[test]
    fn total_bytes_sums_attachment_sizes() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        upsert(&guard, &attachment('f', "a.png")).expect("upsert");
        upsert(&guard, &attachment('0', "b.png")).expect("upsert");
        assert_eq!(total_bytes(&guard).expect("sum"), 2048);
    }
}
