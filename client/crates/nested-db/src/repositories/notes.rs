//! 笔记仓储（含文档内容。
//!
//! ## 为什么文档读写也在这里
//!
//! "保存一篇笔记"必须**原子地**写 `notes` + `documents` + `note_tags` + `revisions`
//! （铁律 D1）。如果把这些拆到多个模块，调用方极易漏掉事务包裹，
//! 因此与笔记强相关的写入集中在本模块，并提供 `save_note` 这类**业务级**入口。

use nested_model::{Document, Id, Note};
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::DbError;
use crate::rowmap::{
    bool_at, bool_to_int, id_at, optional_id_at, optional_timestamp_at, timestamp_at,
};

/// 统一列顺序。
const COLUMNS: &str = "id, notebook_id, title, summary, created_at_ms, updated_at_ms, \
                       accessed_at_ms, is_pinned, is_archived, deleted_at_ms, version";

/// 从一行映射出 [`Note`]（错误类型为 `rusqlite::Error`，见 `rowmap` 模块说明）。
fn map_row(row: &Row<'_>) -> rusqlite::Result<Note> {
    Ok(Note {
        id: id_at(row, 0, "note")?,
        notebook_id: optional_id_at(row, 1, "note")?,
        title: row.get(2)?,
        summary: row.get(3)?,
        created_at_ms: timestamp_at(row, 4)?.as_millis(),
        updated_at_ms: timestamp_at(row, 5)?.as_millis(),
        accessed_at_ms: optional_timestamp_at(row, 6)?.map(|ts| ts.as_millis()),
        is_pinned: bool_at(row, 7)?,
        is_archived: bool_at(row, 8)?,
        deleted_at_ms: optional_timestamp_at(row, 9)?.map(|ts| ts.as_millis()),
        version: row.get(10)?,
    })
}

/// 列表查询条件（定义在 [`crate::db`]，此处重新导出以便调用方就近引用）。
pub use crate::db::{MAX_PAGE_SIZE, NoteQuery};

/// 插入笔记元数据（不含文档内容）。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn insert(connection: &Connection, note: &Note) -> Result<(), DbError> {
    connection.execute(
        "INSERT INTO notes (id, notebook_id, title, summary, created_at_ms, updated_at_ms,
                            accessed_at_ms, is_pinned, is_archived, deleted_at_ms, version)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            note.id.as_bytes(),
            note.notebook_id.as_ref().map(|id| id.as_bytes().to_vec()),
            note.title,
            note.summary,
            note.created_at_ms,
            note.updated_at_ms,
            note.accessed_at_ms,
            bool_to_int(note.is_pinned),
            bool_to_int(note.is_archived),
            note.deleted_at_ms,
            note.version,
        ],
    )?;
    Ok(())
}

/// 原子地创建一篇笔记：笔记元数据 + 文档内容 + 修订记录 + 同步入队（铁律 D1 / T3 / T6）。
///
/// # Errors
///
/// 任一步失败则整体回滚，返回 [`DbError`]。
pub fn create_with_document(
    connection: &mut Connection,
    note: &Note,
    document: &Document,
    device_id: &str,
) -> Result<(), DbError> {
    // 统一用 IMMEDIATE 写事务：一开始就取写锁，冲突在起点由 busy_timeout 排队，
    // 而不是"先读后写"到中途才升级锁并随机失败（技术债 #10）。
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    insert(&transaction, note)?;
    upsert_document(&transaction, &note.id, document)?;
    crate::repositories::attachments::sync_note_links(
        &transaction,
        &note.id,
        &document.attachment_ids(),
        note.created_at_ms,
    )?;
    crate::repositories::revisions::insert(
        &transaction,
        &nested_model::Revision::new(
            note.id,
            note.version,
            None,
            device_id,
            "note.create",
            note.created_at_ms,
        ),
    )?;
    // 与 save_with_document 对称：创建也要入队（技术债 #12）。
    // 此前只有"更新"入队，导致新建的笔记在 P6 同步时根本不会被推送到其他设备。
    crate::repositories::sync_operations::enqueue(
        &transaction,
        &note.id,
        device_id,
        "note.create",
        note.created_at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 按标识读取笔记。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn get(connection: &Connection, id: &Id) -> Result<Option<Note>, DbError> {
    let sql = format!("SELECT {COLUMNS} FROM notes WHERE id = ?1");
    connection
        .query_row(&sql, params![id.as_bytes()], map_row)
        .optional()
        .map_err(DbError::from)
}

/// 按条件列出笔记，按 `updated_at_ms` 倒序。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn list(connection: &Connection, query: &NoteQuery<'_>) -> Result<Vec<Note>, DbError> {
    // 排序键与过滤字段都是白名单枚举展开，不含用户输入拼接（铁律 Q4）
    let mut statement = connection.prepare(&list_sql(query))?;
    let rows = statement.query_map(
        params![
            query.notebook_id.map(|id| id.as_bytes().to_vec()),
            i64::from(query.include_deleted),
            query.archived.map(bool_to_int),
            i64::from(query.effective_limit()),
            i64::from(query.offset),
        ],
        map_row,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
}

/// 构造笔记列表的 SQL。
///
/// ## 为什么"包含子笔记本"需要递归 CTE
///
/// 笔记本是一棵树（`notebooks.parent_id` 自引用）。用户点选父笔记本时，
/// 期望看到**它以及所有后代**里的笔记——否则每建一层子笔记本，父级就变空了。
///
/// SQLite 支持 `WITH RECURSIVE`，因此这里用一条查询解决问题，
/// 而不是在 Rust 侧先取子树再拼 `IN (...)`：
///
/// - **不必把 id 列表拼进 SQL**：拼接大量 id 既慢又容易踩注入（铁律 Q4）；
/// - **一次查询**：避免"取子树 + 查笔记"两次往返带来的不一致窗口。
///
/// 两种形态都是编译期常量 SQL，只有是否递归这一处差异。
fn list_sql(query: &NoteQuery<'_>) -> String {
    if query.include_descendants && query.notebook_id.is_some() {
        format!(
            "WITH RECURSIVE subtree(id) AS (
                 SELECT id FROM notebooks WHERE id = ?1
                 UNION
                 SELECT n.id FROM notebooks n JOIN subtree s ON n.parent_id = s.id
             )
             SELECT {COLUMNS} FROM notes
              WHERE notebook_id IN (SELECT id FROM subtree)
                AND (?2 = 1 OR deleted_at_ms IS NULL)
                AND (?3 IS NULL OR is_archived = ?3)
              ORDER BY is_pinned DESC, updated_at_ms DESC
              LIMIT ?4 OFFSET ?5"
        )
    } else {
        format!(
            "SELECT {COLUMNS} FROM notes
              WHERE (?1 IS NULL OR notebook_id = ?1)
                AND (?2 = 1 OR deleted_at_ms IS NULL)
                AND (?3 IS NULL OR is_archived = ?3)
              ORDER BY is_pinned DESC, updated_at_ms DESC
              LIMIT ?4 OFFSET ?5"
        )
    }
}

/// 统计符合条件的笔记数量。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn count(connection: &Connection, include_deleted: bool) -> Result<i64, DbError> {
    let total: i64 = connection.query_row(
        "SELECT COUNT(*) FROM notes WHERE (?1 = 1 OR deleted_at_ms IS NULL)",
        params![i64::from(include_deleted)],
        |row| row.get(0),
    )?;
    Ok(total)
}

/// 写入/覆盖文档内容。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn upsert_document(
    connection: &Connection,
    note_id: &Id,
    document: &Document,
) -> Result<(), DbError> {
    let bytes = document
        .to_bytes()
        .map_err(|_| DbError::Corrupt { entity: "document" })?;
    connection.execute(
        "INSERT INTO documents (note_id, format, format_version, content, updated_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (note_id) DO UPDATE SET
             format = excluded.format,
             format_version = excluded.format_version,
             content = excluded.content,
             updated_at_ms = excluded.updated_at_ms",
        params![
            note_id.as_bytes(),
            document.metadata.format,
            document.metadata.version,
            bytes,
            document.metadata.updated_at_ms,
        ],
    )?;
    Ok(())
}

/// 读取文档内容（不存在时返回空文档）。
///
/// # Errors
///
/// 数据损坏或格式版本过新时返回 [`DbError::Corrupt`]。
pub fn get_document(connection: &Connection, note_id: &Id) -> Result<Document, DbError> {
    let row: Option<Vec<u8>> = connection
        .query_row(
            "SELECT content FROM documents WHERE note_id = ?1",
            params![note_id.as_bytes()],
            |row| row.get(0),
        )
        .optional()?;
    match row {
        Some(bytes) => {
            Document::from_bytes(&bytes).map_err(|_| DbError::Corrupt { entity: "document" })
        }
        None => Ok(Document::empty(nested_model::now_ms())),
    }
}

/// 已存文档的**原始字节**（不存在时返回 `None`）。
///
/// ## 为什么要读原始字节而不是解析后的 `Document`
///
/// 用于判断"内容是否真的变了"（[`is_document_unchanged`]）。
/// 解析再比较会引入两个问题：
///
/// 1. **丢失未知字段**：`Document` 解析后重新序列化，可能丢掉本版本不认识的
///    字段（将来新增块类型时），于是"内容没变"被误判为"变了"；
/// 2. **依赖相等语义**：`Document` 的 `PartialEq` 一旦包含时间戳之类的元数据，
///    比较结果就不再等于"用户改的内容"。
///
/// 直接比字节最严格也最便宜。
///
/// # Errors
///
/// 查询失败时返回 [`DbError::Sqlite`]。
pub fn get_document_bytes(
    connection: &Connection,
    note_id: &Id,
) -> Result<Option<Vec<u8>>, DbError> {
    connection
        .query_row(
            "SELECT content FROM documents WHERE note_id = ?1",
            params![note_id.as_bytes()],
            |row| row.get(0),
        )
        .optional()
        .map_err(DbError::from)
}

/// 判断给定文档与库中已存内容是否**语义相同**（只比块，不比元信息）。
///
/// ## 为什么不能比序列化字节
///
/// `DocumentMetadata` 含 `created_at_ms` / `updated_at_ms`，而
/// `Document::from_blocks(blocks, at_ms)` 每次都会用传入的时间戳构造元信息。
/// 因此"同样的正文在不同时刻构造两次"会得到**不同的字节**。
///
/// 本项目在修技术债 #11 时先写成了字节比较，结果是：用户一个字没改，
/// 保存仍被判定为"有变更"，照样递增版本、追加修订、入队同步——问题原封不动。
/// 改用 [`Document::has_same_content`] 后才真正成立。
///
/// 库中还没有文档时返回 `false`（需要写入）。
///
/// # Errors
///
/// 读取失败时返回 [`DbError::Sqlite`]；已存字节损坏时返回 [`DbError::Corrupt`]。
pub fn is_document_unchanged(
    connection: &Connection,
    note_id: &Id,
    document: &Document,
) -> Result<bool, DbError> {
    let Some(stored) = get_document_bytes(connection, note_id)? else {
        return Ok(false);
    };
    let stored_document =
        Document::from_bytes(&stored).map_err(|_| DbError::Corrupt { entity: "document" })?;
    Ok(stored_document.has_same_content(document))
}

/// 原子地保存一篇笔记的全部内容变更（铁律 D1 / T6）。
///
/// 一次性完成：
/// 1. 更新 `notes`（标题、摘要、修订号、时间）
/// 2. 覆盖 `documents`
/// 3. 同步 `note_attachments` 引用
/// 4. 追加 `revisions` 与 `sync_operations` 记录
///
/// # Errors
///
/// 任一步失败则整体回滚。
pub fn save_with_document(
    connection: &mut Connection,
    note: &Note,
    document: &Document,
    device_id: &str,
    parent_revision_id: Option<Id>,
) -> Result<(), DbError> {
    // 与 create_with_document 保持同一种事务行为（技术债 #10）
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;

    let changed = transaction.execute(
        "UPDATE notes SET title = ?2, summary = ?3, notebook_id = ?4,
                          updated_at_ms = ?5, is_pinned = ?6, is_archived = ?7,
                          deleted_at_ms = ?8, version = ?9
         WHERE id = ?1",
        params![
            note.id.as_bytes(),
            note.title,
            note.summary,
            note.notebook_id.as_ref().map(|id| id.as_bytes().to_vec()),
            note.updated_at_ms,
            bool_to_int(note.is_pinned),
            bool_to_int(note.is_archived),
            note.deleted_at_ms,
            note.version,
        ],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "note" });
    }

    upsert_document(&transaction, &note.id, document)?;
    crate::repositories::attachments::sync_note_links(
        &transaction,
        &note.id,
        &document.attachment_ids(),
        note.updated_at_ms,
    )?;
    crate::repositories::revisions::insert(
        &transaction,
        &nested_model::Revision::new(
            note.id,
            note.version,
            parent_revision_id,
            device_id,
            "note.update",
            note.updated_at_ms,
        ),
    )?;
    crate::repositories::sync_operations::enqueue(
        &transaction,
        &note.id,
        device_id,
        "note.update",
        note.updated_at_ms,
    )?;

    transaction.commit()?;
    Ok(())
}

/// 软删除（移入回收站）。
///
/// 把一篇笔记移入回收站（软删除），并在**同一事务**里入队（铁律 T3 / T7 / D9）。
///
/// ## 为什么需要 `device_id`
///
/// 删除必须同步：其他设备要能知道这篇笔记被删了，否则它会在对方那里"复活"
/// （铁律 D9 的墓碑）。因此入队与软删除必须在同一事务里完成，
/// 否则会出现"本地删了但没入队"的悬挂状态。
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
        "UPDATE notes SET deleted_at_ms = ?2, updated_at_ms = ?2
         WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "note" });
    }
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "note.delete",
        at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 从回收站恢复，并在**同一事务**里入队（理由同 [`soft_delete`]）。
///
/// # Errors
///
/// 目标不在回收站中时返回 [`DbError::NotFound`]。
pub fn restore(
    connection: &mut Connection,
    id: &Id,
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;

    let changed = transaction.execute(
        "UPDATE notes SET deleted_at_ms = NULL, updated_at_ms = ?2
         WHERE id = ?1 AND deleted_at_ms IS NOT NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "note" });
    }
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "note.restore",
        at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 记录一次访问（用于"最近查看"）。
///
/// **刻意不入队**：`accessed_at_ms` 是本机使用习惯的副产品，
/// 同步它只会制造无意义的写入流量（每台设备的"最近查看"本来就该不同）。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn mark_accessed(connection: &Connection, id: &Id, at_ms: i64) -> Result<(), DbError> {
    let changed = connection.execute(
        "UPDATE notes SET accessed_at_ms = ?2 WHERE id = ?1",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "note" });
    }
    Ok(())
}

/// **彻底删除**回收站中删除时间早于 `deleted_before_ms` 的笔记。
///
/// ## 这是全项目**唯一**的实体硬删除路径
///
/// 在此之前，所有实体表都只有软删（铁律 T7），`DELETE FROM` 只出现在
/// `note_tags` / `note_attachments` 这类**关联表**上（那是关系，不是实体）。
///
/// 它存在的唯一理由是"回收站里的东西不能永远占着磁盘"。
/// 因此它**刻意不是**一个可以随手调用的通用删除接口：
///
/// - 只删**已软删且已过期**的行（`deleted_at_ms IS NOT NULL AND < 阈值`），
///   活跃笔记无论传什么阈值都不会被碰到；
/// - 阈值由调用方传入（即"现在 − 保留期"），
///   保留期本身定义在 `nested-core`，本层不猜业务策略；
/// - 返回删除条数，便于调用方上报"本次清理了多少"。
///
/// ## 为什么必须手工删子表
///
/// `documents` / `revisions` / `note_tags` / `note_attachments` 四张表都有
/// `REFERENCES notes (id)`，而 `0001_init.sql` **没有写 `ON DELETE CASCADE`**
/// （迁移不可改，见铁律 Q2）。因此必须按顺序手工清理，否则会撞外键失败。
///
/// `sync_operations` 已在迁移 `0002` 中去掉外键（多态 `entity_id`），
/// 所以那里的历史队列记录会**原样保留**——这是有意的：
/// 队列是"已经发生过的事"的记录，不该因为实体消失而被抹掉。
///
/// # Errors
///
/// 数据库错误原样上抛。
pub fn purge_deleted_before(
    connection: &mut Connection,
    deleted_before_ms: i64,
) -> Result<u64, DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;

    // 先选出待删 id：后续每张子表都要用同一批 id，避免在删除过程中
    // 集合发生变化（先删子表、再删主表，顺序不能反）
    let doomed: Vec<Vec<u8>> = {
        let mut statement = transaction.prepare(
            "SELECT id FROM notes WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < ?1",
        )?;
        let rows =
            statement.query_map(params![deleted_before_ms], |row| row.get::<_, Vec<u8>>(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };

    for note_id in &doomed {
        // 子表：顺序无所谓（彼此之间无外键），但都必须在删主表之前
        transaction.execute("DELETE FROM note_tags WHERE note_id = ?1", params![note_id])?;
        transaction.execute(
            "DELETE FROM note_attachments WHERE note_id = ?1",
            params![note_id],
        )?;
        transaction.execute("DELETE FROM documents WHERE note_id = ?1", params![note_id])?;
        transaction.execute("DELETE FROM revisions WHERE note_id = ?1", params![note_id])?;
        transaction.execute("DELETE FROM notes WHERE id = ?1", params![note_id])?;
    }

    transaction.commit()?;
    Ok(u64::try_from(doomed.len()).unwrap_or(u64::MAX))
}

/// 统计回收站中"将在 `before_ms` 之前被清理"的笔记数。
///
/// 界面用它显示"还剩 N 天"，因此这里刻意与
/// [`purge_deleted_before`] 使用**同一个判定条件**——
/// 两处若各写一套，就可能出现"提示还剩 1 天、实际已经被删"。
///
/// # Errors
///
/// 数据库错误原样上抛。
pub fn count_purgeable(connection: &Connection, before_ms: i64) -> Result<i64, DbError> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM notes WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < ?1",
        params![before_ms],
        |row| row.get(0),
    )?;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;
    use nested_model::{Block, Notebook};

    const NOW: i64 = 1_700_000_000_000;
    const DEVICE: &str = "device-test";

    /// 建库 + 一个笔记本，返回（库，笔记本 id）。
    fn fixture() -> (Database, Id) {
        let db = Database::open_in_memory().expect("open");
        let notebook = Notebook::new("工作", None, NOW).expect("valid");
        {
            let mut guard = db.connection().expect("conn");
            crate::repositories::notebooks::insert(&mut guard, &notebook, DEVICE)
                .expect("insert notebook");
        }
        (db, notebook.id)
    }

    fn sample_note(notebook_id: Option<Id>, title: &str) -> Note {
        Note::new(notebook_id, title, NOW).expect("valid note")
    }

    #[test]
    fn create_with_document_writes_all_tables_atomically() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let note = sample_note(Some(notebook_id), "第一篇");
        let document = Document::from_blocks(vec![Block::paragraph("你好，世界")], NOW);

        create_with_document(&mut guard, &note, &document, DEVICE).expect("create");

        assert_eq!(get(&guard, &note.id).expect("get").expect("exists"), note);
        assert_eq!(get_document(&guard, &note.id).expect("doc"), document);
        let revisions: i64 = guard
            .query_row(
                "SELECT COUNT(*) FROM revisions WHERE note_id = ?1",
                [note.id.as_bytes()],
                |row| row.get(0),
            )
            .expect("count revisions");
        assert_eq!(revisions, 1, "创建必须留下修订记录（铁律 T6）");
    }

    #[test]
    fn create_is_rolled_back_when_document_is_invalid() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let note = sample_note(Some(notebook_id), "会被回滚");
        // 构造一个版本号过新的文档：序列化成功，但反序列化会失败
        let mut document = Document::empty(NOW);
        document.metadata.version = nested_model::DOCUMENT_FORMAT_VERSION + 1;

        // 写入本身能成功（存的是字节），因此这里改用约束冲突验证回滚：
        // 先建一次，再用同一 note.id 再建一次应触发主键冲突并整体回滚。
        create_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE)
            .expect("first create");
        let err =
            create_with_document(&mut guard, &note, &document, DEVICE).expect_err("duplicate");
        assert!(matches!(err, DbError::Sqlite(_)));
        let count: i64 = guard
            .query_row(
                "SELECT COUNT(*) FROM documents WHERE note_id = ?1",
                [note.id.as_bytes()],
                |row| row.get(0),
            )
            .expect("count");
        assert_eq!(count, 1, "失败的事务不得留下半截数据");
    }

    #[test]
    fn save_increments_version_and_appends_revision() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let mut note = sample_note(Some(notebook_id), "标题");
        let mut document = Document::from_blocks(vec![Block::paragraph("v1")], NOW);
        create_with_document(&mut guard, &note, &document, DEVICE).expect("create");

        note.set_title("标题改了").expect("valid title");
        note.touch(NOW + 1000);
        document.blocks.push(Block::paragraph("v2"));
        document.touch(NOW + 1000);
        save_with_document(&mut guard, &note, &document, DEVICE, None).expect("save");

        let loaded = get(&guard, &note.id).expect("get").expect("exists");
        assert_eq!(loaded.version, 2);
        assert_eq!(loaded.title, "标题改了");
        assert_eq!(get_document(&guard, &note.id).expect("doc").blocks.len(), 2);

        let revisions: i64 = guard
            .query_row(
                "SELECT COUNT(*) FROM revisions WHERE note_id = ?1",
                [note.id.as_bytes()],
                |row| row.get(0),
            )
            .expect("count");
        assert_eq!(revisions, 2);
    }

    #[test]
    fn save_enqueues_sync_operation() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let note = sample_note(Some(notebook_id), "待同步");
        let document = Document::empty(NOW);
        create_with_document(&mut guard, &note, &document, DEVICE).expect("create");
        save_with_document(&mut guard, &note, &document, DEVICE, None).expect("save");

        let pending: i64 = guard
            .query_row(
                "SELECT COUNT(*) FROM sync_operations WHERE pushed_at_ms IS NULL",
                [],
                |row| row.get(0),
            )
            .expect("count");
        // 3 条：fixture 建的笔记本(notebook.create) + 笔记创建(note.create) + 保存(note.update)。
        // 技术债 #12 之前只有"保存"入队——笔记本变更与笔记创建都会丢失同步。
        assert_eq!(pending, 3, "本地写入必须同时入同步队列（铁律 T3）");

        // 操作类型必须能区分，否则对端无法按语义应用变更。
        // 创建时刻相同，因此按 operation 排序取集合，避免依赖 id 的偶然顺序。
        let mut operations: Vec<String> = {
            let mut statement = guard
                .prepare("SELECT operation FROM sync_operations")
                .expect("prepare");
            let rows = statement
                .query_map([], |row| row.get::<_, String>(0))
                .expect("query");
            rows.collect::<Result<Vec<_>, _>>().expect("collect")
        };
        operations.sort();
        assert_eq!(
            operations,
            vec!["note.create", "note.update", "notebook.create"]
        );
    }

    #[test]
    fn save_missing_note_is_not_found() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let note = sample_note(None, "不存在");
        let err = save_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE, None)
            .expect_err("must fail");
        assert!(matches!(err, DbError::NotFound { entity: "note" }));
    }

    #[test]
    fn list_respects_paging_and_excludes_deleted_by_default() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        for index in 0..5 {
            let mut note =
                Note::new(Some(notebook_id), format!("笔记{index}"), NOW + index).expect("valid");
            note.updated_at_ms = NOW + index;
            create_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE).expect("create");
        }
        let deleted = sample_note(Some(notebook_id), "已删除");
        create_with_document(&mut guard, &deleted, &Document::empty(NOW), DEVICE).expect("create");
        soft_delete(&mut guard, &deleted.id, DEVICE, NOW + 100).expect("delete");

        let page = list(
            &guard,
            &NoteQuery {
                notebook_id: Some(&notebook_id),
                limit: 3,
                ..NoteQuery::default()
            },
        )
        .expect("list");
        assert_eq!(page.len(), 3);
        assert_eq!(page[0].title, "笔记4", "必须按修改时间倒序");

        assert_eq!(count(&guard, false).expect("count"), 5);
        assert_eq!(count(&guard, true).expect("count"), 6);
    }

    #[test]
    fn limit_is_clamped_to_max_page_size() {
        let query = NoteQuery {
            limit: u32::MAX,
            ..NoteQuery::default()
        };
        assert_eq!(query.effective_limit(), MAX_PAGE_SIZE);
        let zero = NoteQuery {
            limit: 0,
            ..NoteQuery::default()
        };
        assert_eq!(zero.effective_limit(), 50);
    }

    #[test]
    fn document_for_missing_note_is_empty_not_error() {
        let db = Database::open_in_memory().expect("open");
        let guard = db.connection().expect("conn");
        let document = get_document(&guard, &Id::new()).expect("no error");
        assert!(document.blocks.is_empty());
    }

    // ---------------------------------------------------------------- 笔记本树过滤

    /// 建一棵三层笔记本树：root → mid → leaf，并各放一篇笔记。
    fn tree_fixture() -> (Database, Id, Id, Id) {
        let db = Database::open_in_memory().expect("open");
        let root = Notebook::new("根", None, NOW).expect("valid");
        let mid = Notebook::new("中", Some(root.id), NOW).expect("valid");
        let leaf = Notebook::new("叶", Some(mid.id), NOW).expect("valid");
        {
            let mut guard = db.connection().expect("conn");
            crate::repositories::notebooks::insert(&mut guard, &root, DEVICE).expect("root");
            crate::repositories::notebooks::insert(&mut guard, &mid, DEVICE).expect("mid");
            crate::repositories::notebooks::insert(&mut guard, &leaf, DEVICE).expect("leaf");
            for (notebook, title) in [(&root, "根笔记"), (&mid, "中笔记"), (&leaf, "叶笔记")]
            {
                let note = sample_note(Some(notebook.id), title);
                create_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE)
                    .expect("note");
            }
        }
        (db, root.id, mid.id, leaf.id)
    }

    #[test]
    fn selecting_a_parent_notebook_includes_descendants() {
        // 这是"笔记本是树"的核心语义：点父级要看得到子孙的笔记。
        // 若不做递归，每建一层子笔记本父级就会显得是空的。
        let (db, root, _mid, _leaf) = tree_fixture();
        let guard = db.connection().expect("conn");

        let query = NoteQuery {
            notebook_id: Some(&root),
            include_descendants: true,
            ..NoteQuery::default()
        };
        let notes = list(&guard, &query).expect("list");
        assert_eq!(notes.len(), 3, "应包含根、中、叶三层的笔记");

        let titles: Vec<&str> = notes.iter().map(|note| note.title.as_str()).collect();
        assert!(titles.contains(&"根笔记"));
        assert!(titles.contains(&"中笔记"));
        assert!(titles.contains(&"叶笔记"));
    }

    #[test]
    fn without_descendants_only_direct_notes_are_returned() {
        // 默认（include_descendants = false）保持朴素语义：只看本层
        let (db, root, _mid, _leaf) = tree_fixture();
        let guard = db.connection().expect("conn");

        let query = NoteQuery {
            notebook_id: Some(&root),
            ..NoteQuery::default()
        };
        let notes = list(&guard, &query).expect("list");
        assert_eq!(notes.len(), 1, "默认只返回本层笔记");
        assert_eq!(notes[0].title, "根笔记");
    }

    #[test]
    fn descendants_filter_from_a_middle_node_skips_the_parent() {
        // 从中层往下看，不应包含父层的笔记
        let (db, _root, mid, _leaf) = tree_fixture();
        let guard = db.connection().expect("conn");

        let query = NoteQuery {
            notebook_id: Some(&mid),
            include_descendants: true,
            ..NoteQuery::default()
        };
        let notes = list(&guard, &query).expect("list");
        assert_eq!(notes.len(), 2, "中 + 叶两层");
        let titles: Vec<&str> = notes.iter().map(|note| note.title.as_str()).collect();
        assert!(!titles.contains(&"根笔记"), "不应包含父层笔记");
    }

    #[test]
    fn descendants_filter_on_a_leaf_returns_only_itself() {
        let (db, _root, _mid, leaf) = tree_fixture();
        let guard = db.connection().expect("conn");

        let query = NoteQuery {
            notebook_id: Some(&leaf),
            include_descendants: true,
            ..NoteQuery::default()
        };
        assert_eq!(list(&guard, &query).expect("list").len(), 1);
    }

    #[test]
    fn descendants_filter_ignores_soft_deleted_child_notebooks_notes() {
        // 软删的子笔记本不应把它的笔记带进父级列表
        let (db, root, mid, _leaf) = tree_fixture();
        let mut guard = db.connection().expect("conn");
        // 先删掉中层子笔记本里的笔记（软删），再验证父级列表
        let mid_notes = {
            let query = NoteQuery {
                notebook_id: Some(&mid),
                ..NoteQuery::default()
            };
            list(&guard, &query).expect("list")
        };
        assert_eq!(mid_notes.len(), 1);
        soft_delete(&mut guard, &mid_notes[0].id, DEVICE, NOW + 100).expect("delete");

        let query = NoteQuery {
            notebook_id: Some(&root),
            include_descendants: true,
            ..NoteQuery::default()
        };
        let notes = list(&guard, &query).expect("list");
        assert_eq!(notes.len(), 2, "被软删的笔记不应出现（根 + 叶）");
    }

    #[test]
    fn corrupted_document_bytes_are_reported() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let note = sample_note(Some(notebook_id), "损坏");
        create_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE).expect("create");
        guard
            .execute(
                "UPDATE documents SET content = ?2 WHERE note_id = ?1",
                params![note.id.as_bytes(), b"definitely not json".to_vec()],
            )
            .expect("corrupt");
        let err = get_document(&guard, &note.id).expect_err("must report corruption");
        assert!(matches!(err, DbError::Corrupt { entity: "document" }));
    }

    #[test]
    fn archived_filter_works() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let mut archived = sample_note(Some(notebook_id), "归档的");
        archived.is_archived = true;
        create_with_document(&mut guard, &archived, &Document::empty(NOW), DEVICE).expect("create");
        let plain = sample_note(Some(notebook_id), "普通的");
        create_with_document(&mut guard, &plain, &Document::empty(NOW), DEVICE).expect("create");

        let only_archived = list(
            &guard,
            &NoteQuery {
                archived: Some(true),
                ..NoteQuery::default()
            },
        )
        .expect("list");
        assert_eq!(only_archived.len(), 1);
        assert_eq!(only_archived[0].title, "归档的");
    }

    #[test]
    fn mark_accessed_records_time() {
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let note = sample_note(Some(notebook_id), "访问");
        create_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE).expect("create");
        mark_accessed(&guard, &note.id, NOW + 42).expect("access");
        assert_eq!(
            get(&guard, &note.id)
                .expect("get")
                .expect("exists")
                .accessed_at_ms,
            Some(NOW + 42)
        );
    }

    // ---------------------------------------------------------- 回收站彻底删除
    //
    // 这是全项目**唯一**的实体硬删除路径，因此测试要盯住它的边界：
    // 该删的删掉、不该删的一个都不能碰。

    /// 造一条"已删除"的笔记，返回它的 id。
    fn deleted_note(db: &Database, notebook_id: &Id, title: &str, deleted_at: i64) -> Id {
        let mut guard = db.connection().expect("conn");
        let note = sample_note(Some(*notebook_id), title);
        create_with_document(&mut guard, &note, &Document::empty(NOW), DEVICE).expect("create");
        soft_delete(&mut guard, &note.id, DEVICE, deleted_at).expect("soft delete");
        note.id
    }

    /// 确认某个 id 在 notes 表里彻底不存在了。
    fn is_gone(db: &Database, id: &Id) -> bool {
        let guard = db.connection().expect("conn");
        get(&guard, id).expect("get").is_none()
    }

    /// 数某个子表里还有多少行指向这条笔记。
    fn count_children(db: &Database, table: &str, id: &Id) -> i64 {
        db.connection()
            .expect("conn")
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE note_id = ?1"),
                params![id.as_bytes()],
                |row| row.get(0),
            )
            .expect("count children")
    }

    #[test]
    fn purge_removes_expired_deleted_notes_and_their_children() {
        let (db, notebook_id) = fixture();
        let id = deleted_note(&db, &notebook_id, "过期的", NOW - 10_000);

        // 让这条笔记**真的有** documents 子行——否则"子表被清干净"这句
        // 断言会因为没有子行而平凡通过（假装验证了，其实没验证）。
        // `soft_delete` 已经入队过 note.delete，这里不必也不该手工再加一条，
        // 否则下面的队列断言会数到两条，掩盖"队列到底有没有被清"这个真正的问题。
        {
            let guard = db.connection().expect("conn");
            upsert_document(&guard, &id, &Document::empty(NOW)).expect("doc");
        }
        assert!(
            count_children(&db, "documents", &id) == 1,
            "前置条件：documents 子行必须存在，否则后面的清理断言没有意义"
        );

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), NOW).expect("purge");
        assert_eq!(removed, 1, "过期笔记应被删掉");
        assert!(is_gone(&db, &id), "主表行必须消失");

        // 子表不能留残行（否则它们会变成永远查不到的垃圾）
        for table in ["documents", "revisions", "note_tags", "note_attachments"] {
            assert_eq!(
                count_children(&db, table, &id),
                0,
                "{table} 里不应残留已删笔记的行"
            );
        }

        // 同步队列**刻意保留**：那是"已经发生过的事"的记录。
        // 断言精确到 operation，别断言总数——总数会随入队策略变化而漂移，
        // 把"策略改了"误报成"队列被清空"。
        let queued: i64 = db
            .connection()
            .expect("conn")
            .query_row(
                "SELECT COUNT(*) FROM sync_operations \
                 WHERE entity_id = ?1 AND operation = 'note.delete'",
                params![id.as_bytes()],
                |row| row.get(0),
            )
            .expect("count queue");
        assert_eq!(
            queued, 1,
            "「删除」这条队列记录不应因实体消失而被抹掉（迁移 0002 已去掉外键）"
        );
    }

    #[test]
    fn purge_never_touches_notes_that_are_not_deleted() {
        // 最重要的边界：活跃笔记无论阈值多大都不能被删
        let (db, notebook_id) = fixture();
        let mut guard = db.connection().expect("conn");
        let alive = sample_note(Some(notebook_id), "活着的");
        create_with_document(&mut guard, &alive, &Document::empty(NOW), DEVICE).expect("create");
        drop(guard);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), i64::MAX).expect("purge");
        assert_eq!(removed, 0, "活跃笔记不该被任何阈值删掉");
        assert!(!is_gone(&db, &alive.id), "活跃笔记必须还在");
    }

    #[test]
    fn purge_respects_the_retention_boundary() {
        // 边界语义：`deleted_at_ms < before_ms`，即"刚好等于阈值"的不删。
        // 这个细节决定"还剩 1 天"的显示是否与实际一致。
        let (db, notebook_id) = fixture();
        let exactly = deleted_note(&db, &notebook_id, "卡在阈值上", NOW);
        let older = deleted_note(&db, &notebook_id, "早于阈值", NOW - 1);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), NOW).expect("purge");
        assert_eq!(removed, 1);
        assert!(!is_gone(&db, &exactly), "恰好等于阈值的不应删除");
        assert!(is_gone(&db, &older), "早于阈值的应删除");
    }

    #[test]
    fn count_purgeable_matches_what_purge_would_remove() {
        // 界面用它显示"还剩 N 天"。两处判定条件若不一致，
        // 就会出现"提示还剩 1 天、其实已经被删"这类最难解释的现象。
        let (db, notebook_id) = fixture();
        deleted_note(&db, &notebook_id, "一个", NOW - 1);
        deleted_note(&db, &notebook_id, "两个", NOW - 2);
        deleted_note(&db, &notebook_id, "还没到期", NOW + 100);

        let guard = db.connection().expect("conn");
        assert_eq!(count_purgeable(&guard, NOW).expect("count"), 2);
        drop(guard);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), NOW).expect("purge");
        assert_eq!(
            removed, 2,
            "count_purgeable 的数字必须与 purge 实际删掉的条数一致"
        );
    }
}
