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

/// 插入一个笔记本，并在**同一事务**里入队（铁律 T3 / D1）。
///
/// 笔记本也会在多设备间同步，因此它的创建同样必须入队——
/// 否则新设备永远看不到这个笔记本（技术债 #12：此前只有笔记更新入队）。
///
/// # Errors
///
/// 主键冲突或写入失败时返回 [`DbError`]。
pub fn insert(
    connection: &mut Connection,
    notebook: &Notebook,
    device_id: &str,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    insert_in_transaction(&transaction, notebook)?;
    crate::repositories::sync_operations::enqueue(
        &transaction,
        &notebook.id,
        device_id,
        "notebook.create",
        notebook.created_at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 在给定事务内插入笔记本（供其它事务复用，不自行开关事务）。
///
/// # Errors
///
/// 写入失败时返回 [`DbError`]。
pub fn insert_in_transaction(connection: &Connection, notebook: &Notebook) -> Result<(), DbError> {
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

/// 重命名（同一事务入队）。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn rename(
    connection: &mut Connection,
    id: &Id,
    name: &str,
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    let changed = transaction.execute(
        "UPDATE notebooks SET name = ?2, updated_at_ms = ?3
         WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), name, at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "notebook" });
    }
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "notebook.update",
        at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 软删除（移入回收站，同一事务入队）。
///
/// **注意**：不会级联删除子笔记本与笔记——级联策略由 `nested-core` 的业务规则决定，
/// 仓储层只负责一次写入（铁律 A7）。
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
        "UPDATE notebooks SET deleted_at_ms = ?2, updated_at_ms = ?2
         WHERE id = ?1 AND deleted_at_ms IS NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "notebook" });
    }
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "notebook.delete",
        at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}

/// 把笔记本移动到另一个父节点下（`new_parent` 为 `None` 表示移到顶层）。
///
/// ## 为什么要在这里做环检测，而不是交给调用方
///
/// `notebooks.parent_id` 是自引用外键，**数据库不会阻止成环**：
/// 把祖先移到自己的后代下，SQL 完全接受，外键也满足。
/// 但之后任何深度优先遍历（`list_notebook_tree`、`notebook_subtree_ids`）
/// 都会**无限递归**——表现为界面卡死或栈溢出，而不是报错。
///
/// 这类缺陷的排查成本极高（数据看起来正常，只是程序不动了），
/// 而检测它的代价只是一次子树查询。因此放在写入口，
/// 让"不可能成环"成为这一层的保证（铁律 T4：规则在 Core/仓储，不在 UI）。
///
/// # Errors
///
/// - 目标笔记本不存在 → [`DbError::NotFound`]
/// - `new_parent` 指向自己或自己的后代 → [`DbError::WouldCreateCycle`]
/// - `new_parent` 不存在 → [`DbError::NotFound`]
pub fn move_to_parent(
    connection: &mut Connection,
    id: &Id,
    new_parent: Option<&Id>,
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;

    // 目标必须存在（且未删除）
    let exists: Option<i64> = transaction
        .query_row(
            "SELECT 1 FROM notebooks WHERE id = ?1",
            params![id.as_bytes()],
            |row| row.get(0),
        )
        .optional()?;
    if exists.is_none() {
        return Err(DbError::NotFound { entity: "notebook" });
    }

    if let Some(parent) = new_parent {
        if parent == id {
            return Err(DbError::WouldCreateCycle);
        }
        // 新父节点必须存在
        let parent_exists: Option<i64> = transaction
            .query_row(
                "SELECT 1 FROM notebooks WHERE id = ?1",
                params![parent.as_bytes()],
                |row| row.get(0),
            )
            .optional()?;
        if parent_exists.is_none() {
            return Err(DbError::NotFound { entity: "notebook" });
        }

        // 环检测：新父节点若在**自己的子树**里，移动就会成环。
        // 递归 CTE 从自己出发向下走，看能否走到新父节点。
        let would_cycle: Option<i64> = transaction
            .query_row(
                "WITH RECURSIVE subtree(id) AS (
                     SELECT id FROM notebooks WHERE id = ?1
                     UNION
                     SELECT child.id FROM notebooks child
                     JOIN subtree ON child.parent_id = subtree.id
                 )
                 SELECT 1 FROM subtree WHERE id = ?2",
                params![id.as_bytes(), parent.as_bytes()],
                |row| row.get(0),
            )
            .optional()?;
        if would_cycle.is_some() {
            return Err(DbError::WouldCreateCycle);
        }
    }

    let parent_bytes = new_parent.map(nested_model::Id::as_bytes);
    transaction.execute(
        "UPDATE notebooks SET parent_id = ?2, updated_at_ms = ?3 WHERE id = ?1",
        params![id.as_bytes(), parent_bytes, at_ms],
    )?;
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "notebook.move",
        at_ms,
    )?;
    transaction.commit()?;
    Ok(())
}
/// 从回收站恢复（同一事务入队）。
///
/// # Errors
///
/// 目标不存在时返回 [`DbError::NotFound`]。
pub fn restore(
    connection: &mut Connection,
    id: &Id,
    device_id: &str,
    at_ms: i64,
) -> Result<(), DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;
    let changed = transaction.execute(
        "UPDATE notebooks SET deleted_at_ms = NULL, updated_at_ms = ?2
         WHERE id = ?1 AND deleted_at_ms IS NOT NULL",
        params![id.as_bytes(), at_ms],
    )?;
    if changed == 0 {
        return Err(DbError::NotFound { entity: "notebook" });
    }
    crate::repositories::sync_operations::enqueue(
        &transaction,
        id,
        device_id,
        "notebook.restore",
        at_ms,
    )?;
    transaction.commit()?;
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

/// **彻底删除**回收站中删除时间早于 `deleted_before_ms`、且**已无任何引用**的笔记本。
///
/// ## 与 [`crate::repositories::notes::purge_deleted_before`] 的关键差别
///
/// 笔记的彻底删除是"删掉它自己和它的子行"。笔记本不能这样做，因为
/// `notes.notebook_id` 与 `notebooks.parent_id` 都指向它，而
/// `0001_init.sql` **没有** `ON DELETE CASCADE`（迁移不可改，铁律 Q2）。
///
/// 更要紧的是**语义**：删掉一个还装着笔记的笔记本，那些笔记会变成
/// 无法定位的孤儿。这与 `delete_notebook` 的既有承诺（"不级联删除其下的笔记"，
/// 见 `nested-core` 的同名方法文档）直接冲突。
///
/// 因此这里采取**保守策略**：只要还有**未彻底删除的**笔记或子笔记本引用它，
/// 就**跳过**这条笔记本——等那些引用先被处理掉，下一轮清理自然会删掉它。
///
/// 这样做的代价是"个别空笔记本可能多留几轮"，换来的是
/// **永远不会因为定时清理而产生孤儿笔记**。这个交换是值得的。
///
/// # Errors
///
/// 数据库错误原样上抛。
pub fn purge_deleted_before(
    connection: &mut Connection,
    deleted_before_ms: i64,
) -> Result<u64, DbError> {
    let transaction = crate::db::begin_write_transaction(&mut *connection)?;

    let changed = transaction.execute(
        "DELETE FROM notebooks
          WHERE deleted_at_ms IS NOT NULL
            AND deleted_at_ms < ?1
            -- 仍有笔记引用（无论笔记自己是否已删）→ 不动
            AND NOT EXISTS (SELECT 1 FROM notes WHERE notes.notebook_id = notebooks.id)
            -- 仍有子笔记本引用 → 不动（否则子笔记本会变成孤儿节点）
            AND NOT EXISTS (
                SELECT 1 FROM notebooks AS child WHERE child.parent_id = notebooks.id
            )",
        params![deleted_before_ms],
    )?;

    transaction.commit()?;
    Ok(u64::try_from(changed).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;

    const NOW: i64 = 1_700_000_000_000;
    const DEVICE: &str = "device-test";

    fn notebook(name: &str) -> Notebook {
        Notebook::new(name, None, NOW).expect("valid notebook")
    }

    #[test]
    fn insert_then_get_roundtrips() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let original = notebook("工作");
        insert(&mut guard, &original, DEVICE).expect("insert");
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
        let mut guard = db.connection().expect("conn");
        insert(&mut guard, &notebook("beta"), DEVICE).expect("insert");
        insert(&mut guard, &notebook("Alpha"), DEVICE).expect("insert");
        let gone = notebook("删掉的");
        insert(&mut guard, &gone, DEVICE).expect("insert");
        soft_delete(&mut guard, &gone.id, DEVICE, NOW + 1).expect("soft delete");

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
        let mut guard = db.connection().expect("conn");
        let root = notebook("root");
        insert(&mut guard, &root, DEVICE).expect("insert root");
        let child = Notebook::new("child", Some(root.id), NOW).expect("valid");
        insert(&mut guard, &child, DEVICE).expect("insert child");

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
        let mut guard = db.connection().expect("conn");
        let item = notebook("旧名");
        insert(&mut guard, &item, DEVICE).expect("insert");
        rename(&mut guard, &item.id, "新名", DEVICE, NOW + 500).expect("rename");
        let loaded = get(&guard, &item.id).expect("get").expect("exists");
        assert_eq!(loaded.name, "新名");
        assert_eq!(loaded.updated_at_ms, NOW + 500);
    }

    #[test]
    fn rename_missing_is_not_found() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let err = rename(&mut guard, &Id::new(), "x", DEVICE, NOW).expect_err("must fail");
        assert!(matches!(err, DbError::NotFound { entity: "notebook" }));
    }

    #[test]
    fn soft_delete_then_restore_is_reversible() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let item = notebook("回收站往返");
        insert(&mut guard, &item, DEVICE).expect("insert");

        soft_delete(&mut guard, &item.id, DEVICE, NOW + 1).expect("delete");
        assert!(
            get(&guard, &item.id)
                .expect("get")
                .expect("exists")
                .is_deleted()
        );

        restore(&mut guard, &item.id, DEVICE, NOW + 2).expect("restore");
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
        let mut guard = db.connection().expect("conn");
        let item = notebook("重复删除");
        insert(&mut guard, &item, DEVICE).expect("insert");
        soft_delete(&mut guard, &item.id, DEVICE, NOW + 1).expect("first");
        assert!(soft_delete(&mut guard, &item.id, DEVICE, NOW + 2).is_err());
    }

    #[test]
    fn row_is_never_physically_removed_by_soft_delete() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let item = notebook("墓碑");
        insert(&mut guard, &item, DEVICE).expect("insert");
        soft_delete(&mut guard, &item.id, DEVICE, NOW + 1).expect("delete");
        let total: i64 = guard
            .query_row("SELECT COUNT(*) FROM notebooks", [], |row| row.get(0))
            .expect("count");
        assert_eq!(total, 1, "软删除必须保留行（同步需要墓碑，铁律 D9）");
    }

    // -------------------------------------------------------------- 移动与环
    //
    // 成环是"数据看起来正常、程序无限递归"的那类缺陷：
    // 数据库完全不反对，遍历却会卡死。因此这些测试盯的是**正确性**，
    // 不只是功能。

    /// 建一个 A → B → C 的三层链，返回 (a, b, c)。
    fn chain(db: &Database) -> (Notebook, Notebook, Notebook) {
        let mut guard = db.connection().expect("conn");
        let a = notebook("A");
        insert(&mut guard, &a, DEVICE).expect("insert a");
        let b = Notebook::new("B", Some(a.id), NOW).expect("b");
        insert(&mut guard, &b, DEVICE).expect("insert b");
        let c = Notebook::new("C", Some(b.id), NOW).expect("c");
        insert(&mut guard, &c, DEVICE).expect("insert c");
        (a, b, c)
    }

    #[test]
    fn move_to_parent_reparents_a_notebook() {
        let db = Database::open_in_memory().expect("open");
        let (a, _b, c) = chain(&db);
        // 把 C 直接挂到 A 下（跨层移动是允许的）
        move_to_parent(
            &mut db.connection().expect("conn"),
            &c.id,
            Some(&a.id),
            DEVICE,
            NOW + 1,
        )
        .expect("move");
        let guard = db.connection().expect("conn");
        assert_eq!(
            get(&guard, &c.id).expect("get").expect("exists").parent_id,
            Some(a.id)
        );
    }

    #[test]
    fn move_to_parent_can_promote_to_top_level() {
        let db = Database::open_in_memory().expect("open");
        let (_a, b, _c) = chain(&db);
        move_to_parent(
            &mut db.connection().expect("conn"),
            &b.id,
            None,
            DEVICE,
            NOW + 1,
        )
        .expect("move");
        let guard = db.connection().expect("conn");
        assert_eq!(
            get(&guard, &b.id).expect("get").expect("exists").parent_id,
            None,
            "传 None 应移到顶层"
        );
    }

    #[test]
    fn move_into_own_descendant_is_rejected() {
        // 核心用例：A → B → C，把 A 移到 C 下会成环。
        // 数据库会欣然接受，所以拦不住的话，之后 list_notebook_tree
        // 就会无限递归（表现为界面卡死）。
        let db = Database::open_in_memory().expect("open");
        let (a, _b, c) = chain(&db);
        let error = move_to_parent(
            &mut db.connection().expect("conn"),
            &a.id,
            Some(&c.id),
            DEVICE,
            NOW + 1,
        )
        .expect_err("把祖先移到后代下必须被拒绝");
        assert!(
            matches!(error, DbError::WouldCreateCycle),
            "实际错误：{error:?}"
        );

        // 拒绝之后树必须保持原样（不能出现"半移动"状态）
        let guard = db.connection().expect("conn");
        assert_eq!(
            get(&guard, &a.id).expect("get").expect("exists").parent_id,
            None,
            "被拒绝的移动不应改动任何数据"
        );
    }

    #[test]
    fn move_onto_itself_is_rejected() {
        let db = Database::open_in_memory().expect("open");
        let (a, _b, _c) = chain(&db);
        let error = move_to_parent(
            &mut db.connection().expect("conn"),
            &a.id,
            Some(&a.id),
            DEVICE,
            NOW + 1,
        )
        .expect_err("移到自己下面必须被拒绝");
        assert!(matches!(error, DbError::WouldCreateCycle));
    }

    #[test]
    fn moving_a_sibling_under_another_sibling_is_fine() {
        // 反例对照：C 挂到 B 下（B 是 C 的父）之外的**兄弟**关系不该被误判成环。
        // 没有这条，"环检测"写成"只要 target 在树里就拒绝"也能通过上面的测试。
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let root = notebook("根");
        insert(&mut guard, &root, DEVICE).expect("root");
        let x = Notebook::new("X", Some(root.id), NOW).expect("x");
        insert(&mut guard, &x, DEVICE).expect("x");
        let y = Notebook::new("Y", Some(root.id), NOW).expect("y");
        insert(&mut guard, &y, DEVICE).expect("y");
        drop(guard);

        move_to_parent(
            &mut db.connection().expect("conn"),
            &x.id,
            Some(&y.id),
            DEVICE,
            NOW + 1,
        )
        .expect("兄弟之间移动是合法的，不该被环检测拦住");
    }

    #[test]
    fn move_to_missing_parent_is_rejected() {
        let db = Database::open_in_memory().expect("open");
        let (a, _b, _c) = chain(&db);
        let error = move_to_parent(
            &mut db.connection().expect("conn"),
            &a.id,
            Some(&Id::new()),
            DEVICE,
            NOW + 1,
        )
        .expect_err("目标父节点不存在时必须报错");
        assert!(matches!(error, DbError::NotFound { .. }));
    }

    // ------------------------------------------------------------ 回收站清理

    #[test]
    fn purge_removes_an_expired_empty_notebook() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let item = notebook("空的");
        insert(&mut guard, &item, DEVICE).expect("insert");
        soft_delete(&mut guard, &item.id, DEVICE, NOW - 100).expect("delete");
        drop(guard);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), NOW).expect("purge");
        assert_eq!(removed, 1);
        let guard = db.connection().expect("conn");
        assert!(
            get(&guard, &item.id).expect("get").is_none(),
            "行应彻底消失"
        );
    }

    #[test]
    fn purge_skips_a_notebook_that_still_has_notes() {
        // 关键的安全性质：定时清理**绝不能**产生孤儿笔记。
        // 删除笔记本的既有语义是"不级联删它的笔记"，清理也必须守这条。
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let book = notebook("还有笔记");
        insert(&mut guard, &book, DEVICE).expect("insert");
        // 直接插一条笔记（不需要 documents，够触发引用即可）
        guard
            .execute(
                "INSERT INTO notes (id, notebook_id, title, summary, created_at_ms,
                                    updated_at_ms, is_pinned, is_archived, version)
                 VALUES (?1, ?2, 'x', '', ?3, ?3, 0, 0, 1)",
                params![Id::new().as_bytes(), book.id.as_bytes(), NOW],
            )
            .expect("insert note");
        soft_delete(&mut guard, &book.id, DEVICE, NOW - 100).expect("delete");
        drop(guard);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), NOW).expect("purge");
        assert_eq!(removed, 0, "还有笔记引用时必须跳过");
        let guard = db.connection().expect("conn");
        assert!(
            get(&guard, &book.id).expect("get").is_some(),
            "被跳过的笔记本必须还在——否则它的笔记就成了孤儿"
        );
    }

    #[test]
    fn purge_skips_a_notebook_that_still_has_children() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let parent = notebook("父");
        insert(&mut guard, &parent, DEVICE).expect("parent");
        let child = Notebook::new("子", Some(parent.id), NOW).expect("child");
        insert(&mut guard, &child, DEVICE).expect("child");
        soft_delete(&mut guard, &parent.id, DEVICE, NOW - 100).expect("delete");
        drop(guard);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), NOW).expect("purge");
        assert_eq!(removed, 0, "还有子笔记本引用时必须跳过");
    }

    #[test]
    fn purge_leaves_active_notebooks_alone() {
        let db = Database::open_in_memory().expect("open");
        let mut guard = db.connection().expect("conn");
        let alive = notebook("活着的");
        insert(&mut guard, &alive, DEVICE).expect("insert");
        drop(guard);

        let removed =
            purge_deleted_before(&mut db.connection().expect("conn"), i64::MAX).expect("purge");
        assert_eq!(removed, 0);
        let guard = db.connection().expect("conn");
        assert!(get(&guard, &alive.id).expect("get").is_some());
    }
}
