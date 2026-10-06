//! 笔记操作 —— 跨 FFI 的业务面（P1 最小可用闭环）。
//!
//! ## 设计要点
//!
//! ### 1. 引擎是进程级单例
//!
//! Flutter 侧只有一个内核实例（一个数据目录、一个 SQLite 连接）。因此这里用
//! `OnceLock<RwLock<Option<NestedCore>>>` 持有它：
//!
//! - `OnceLock` 保证全局唯一，且初始化无需加锁（`get_or_init` 只执行一次逻辑）；
//! - `RwLock` 允许多个读操作并发（列表、读内容），写操作独占；
//! - 内核本身内部已有连接锁（`nested_db::Database`），这里再加一层是为了
//!   **替换引擎**（切换数据目录）时的整体一致性。
//!
//! ### 2. 错误一律结构化返回，不 panic（铁律 E1 / E2 / E3）
//!
//! FFI 边界上 panic 会直接终止进程（无法跨语言 unwind），因此所有失败都转成
//! [`NoteResult`]，其中 `code` 是可检索的稳定错误码（来自
//! `nested_core::CoreError::code()`），`hint` 是给用户看的一句话。
//!
//! **不返回堆栈、不返回内部路径**：堆栈对用户没有意义，而且会泄露内部结构。
//!
//! ### 3. 为什么时间戳由 Dart 传入
//!
//! `at_ms` 由调用方提供而不是在这里取 `now()`，好处是：
//!
//! - Rust 侧保持**确定性**（同样的输入产生同样的结果），便于测试；
//! - 时间的"权威来源"只有一个（Dart 的系统时钟），避免两端时钟不一致导致
//!   修订版本排序错乱。
//!
//! Dart 侧用 `DateTime.now().millisecondsSinceEpoch` 提供该值。

use std::sync::{OnceLock, RwLock};

use nested_core::{CoreError, NestedCore, NoteQuery};
use nested_model::{Block, Document, Id, Note};

use crate::api::branding::EngineStatus;

/// 笔记在界面上的表示（**扁平**结构，便于跨语言映射）。
///
/// 刻意不直接暴露 `nested_model::Note`：领域实体的字段会随需求演进，
/// 而跨语言契约应当稳定。这里是"界面需要什么就给什么"。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteSummary {
    /// 笔记标识（UUID 文本形式，界面用它作为 key）。
    pub id: String,
    /// 标题。
    pub title: String,
    /// 摘要（列表第二行）。
    pub summary: String,
    /// 创建时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 最后修改时间（UTC 毫秒）。
    pub updated_at_ms: i64,
    /// 修订号（每次保存递增）。
    pub version: i64,
    /// 是否在回收站。
    pub deleted: bool,
}

/// 一次操作的结果。
///
/// `ok = false` 时 `code` 与 `hint` 一定有值；`value` 为 `None`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteResult {
    /// 是否成功。
    pub ok: bool,
    /// 稳定错误码（如 `"NOT_FOUND"`、`"VALIDATION_ERROR"`），可检索（铁律 E3）。
    pub code: Option<String>,
    /// 面向用户的一句话提示（不含内部细节）。
    pub hint: Option<String>,
    /// 成功时的载荷。
    pub value: Option<NotePayload>,
}

/// 操作成功时的载荷（按操作类型使用其中一部分字段）。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NotePayload {
    /// 单篇笔记（创建/读取/保存时返回）。
    pub note: Option<NoteSummary>,
    /// 笔记列表（列表操作返回）。
    pub notes: Vec<NoteSummary>,
    /// 纯文本内容（读取时返回，行内标记已展平）。
    pub text: Option<String>,
}

impl NoteResult {
    /// 成功。
    #[must_use]
    fn ok(value: NotePayload) -> Self {
        Self {
            ok: true,
            code: None,
            hint: None,
            value: Some(value),
        }
    }

    /// 失败：把 [`CoreError`] 转成可跨语言传递的结构。
    ///
    /// **注意**：这里用 `code()` 与 `user_hint()`，绝不把 `Display` 输出
    /// （可能含路径或 SQL 片段）直接交给界面（铁律 E2）。
    #[must_use]
    fn failed(error: CoreError) -> Self {
        Self {
            ok: false,
            code: Some(error.code().to_owned()),
            hint: Some(error.user_hint().to_owned()),
            value: None,
        }
    }

    /// 引擎尚未启动。
    #[must_use]
    fn not_started() -> Self {
        Self {
            ok: false,
            code: Some("ENGINE_NOT_STARTED".to_owned()),
            hint: Some("笔记引擎尚未就绪，请先重启应用。".to_owned()),
            value: None,
        }
    }
}

/// 进程级引擎句柄。
fn engine() -> &'static RwLock<Option<NestedCore>> {
    static ENGINE: OnceLock<RwLock<Option<NestedCore>>> = OnceLock::new();
    ENGINE.get_or_init(|| RwLock::new(None))
}

/// 测试专用辅助（**不参与 FFI 导出**）。
///
/// ## 为什么需要它
///
/// 引擎是**进程级单例**，而 `cargo test` 默认**并行**执行测试。
/// 只要有任意一个测试调用 `engine_start`，它就会把别的测试正在使用的引擎替换掉，
/// 表现为"刚创建的笔记在下一个调用里变成 NOT_FOUND"——这种失败极具误导性
/// （看起来像数据丢失，实际是测试互相踩）。本项目在接入笔记 API 时就真实踩到过。
///
/// 因此**凡是会启动引擎的测试都必须先取得这把锁**（`branding` 与 `notes` 共用同一把）。
///
/// ## 为什么用 `#[cfg(test)]` 而不是 `#[doc(hidden)]`
///
/// `flutter_rust_bridge` 的代码生成只看可见性、不看文档隐藏标记，
/// 因此 `#[doc(hidden)] pub fn` **仍会被导出到 Dart**。测试辅助不该出现在
/// 跨语言契约里（铁律 A3：导出面必须可控），所以用 `#[cfg(test)]` 彻底排除。
#[cfg(test)]
pub(crate) mod test_support {
    use std::sync::{Mutex, MutexGuard, OnceLock};

    /// 取得"独占全局引擎"的测试锁。
    pub(crate) fn engine_lock() -> MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            // 某个测试 panic 不该让其余测试全部失败：中毒后继续用即可
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// 在给定数据目录启动内核（幂等：重复调用会替换为新引擎）。
///
/// 返回值与 P0 的 [`crate::api::branding::start_engine`] 相同，便于界面统一处理。
#[must_use]
pub fn engine_start(data_dir: &str) -> EngineStatus {
    match NestedCore::open(data_dir) {
        Ok(core) => {
            let checks: Vec<crate::api::branding::EngineCheck> = core
                .readiness()
                .into_iter()
                .map(|(name, passed)| crate::api::branding::EngineCheck {
                    name: name.to_owned(),
                    passed,
                })
                .collect();
            let ready = checks.iter().all(|check| check.passed);
            let database_path = core.database_path().map(|path| path.display().to_string());

            // 装进全局句柄：写锁失败（中毒）也当作启动失败，不能让界面以为就绪
            match engine().write() {
                Ok(mut slot) => *slot = Some(core),
                Err(_) => {
                    return EngineStatus {
                        ready: false,
                        checks,
                        database_path,
                        message: Some("内核状态锁异常，请重启应用。".to_owned()),
                    };
                }
            }

            EngineStatus {
                ready,
                checks,
                database_path,
                message: None,
            }
        }
        Err(error) => EngineStatus {
            ready: false,
            checks: Vec::new(),
            database_path: None,
            message: Some(error.user_hint().to_owned()),
        },
    }
}

/// 在一个已启动的内核上执行操作（读锁）。
fn with_core<T>(f: impl FnOnce(&NestedCore) -> Result<T, CoreError>) -> Result<T, NoteResult> {
    let guard = engine().read().map_err(|_| NoteResult {
        ok: false,
        code: Some("ENGINE_LOCK_FAILED".to_owned()),
        hint: Some("内核状态异常，请重启应用。".to_owned()),
        value: None,
    })?;
    let core = guard.as_ref().ok_or_else(NoteResult::not_started)?;
    f(core).map_err(NoteResult::failed)
}

/// 关闭内核并释放数据库连接。
///
/// ## 为什么需要显式关闭
///
/// 引擎是进程级单例，`NestedCore` 里持有 SQLite 连接。只要它还在，
/// **Windows 就会锁定数据库文件与其 WAL 文件**，导致数据目录无法被删除或移动
/// （`OS Error 32: 另一个程序正在使用此文件`）。这在两个场景会真实咬人：
///
/// - 测试：清理临时数据目录时失败（本项目的 FFI 集成测试就这样失败过一次）；
/// - 将来"切换 / 迁移数据目录"的功能。
///
/// 关闭时会把 WAL 合并回主库（`wal_checkpoint(TRUNCATE)`），
/// 使数据目录里不残留 `.db-wal` / `.db-shm`——这对"拷贝整个目录就是完整备份"
/// 这一用户直觉很重要。
///
/// 与 [`engine_start`] 是幂等配对：未启动时调用返回 `true`，关闭后可再次启动。
#[must_use]
pub fn engine_close() -> bool {
    let mut guard = match engine().write() {
        Ok(guard) => guard,
        Err(_) => return false,
    };
    let Some(core) = guard.take() else {
        // 本来就没启动：幂等，视为成功
        return true;
    };

    // 尽力合并 WAL。失败不影响"已关闭"这一事实，因此不向上报错。
    if let Ok(connection) = core.database().connection()
        && let Err(error) = connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
    {
        tracing::debug!(%error, "WAL 合并失败（不影响关闭）");
    }

    // core 在此离开作用域 → rusqlite 连接被 drop → 文件锁释放
    drop(core);
    true
}

/// 把领域实体转成界面表示。
fn summary_of(note: &Note) -> NoteSummary {
    NoteSummary {
        id: note.id.to_string(),
        title: note.title.clone(),
        summary: note.summary.clone(),
        created_at_ms: note.created_at_ms,
        updated_at_ms: note.updated_at_ms,
        version: note.version,
        deleted: note.deleted_at_ms.is_some(),
    }
}

/// 把文档展平为纯文本（用于简洁的编辑器：一个文本块 = 一个段落）。
///
/// 注意：这只是**展示**用的降级表示。真实编辑器（P3）会直接操作块模型，
/// 不会经过纯文本这一步——这里的目的是让 P1 有一条能看见结果的通路。
fn document_to_text(document: &Document) -> String {
    document
        .blocks
        .iter()
        .map(|block| block.searchable_text())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// 把纯文本转成文档（按换行切分为段落，空行忽略）。
fn text_to_document(text: &str, at_ms: i64) -> Document {
    let blocks: Vec<Block> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| Block::paragraph(line))
        .collect();
    if blocks.is_empty() {
        Document::empty(at_ms)
    } else {
        Document::from_blocks(blocks, at_ms)
    }
}

/// 解析界面传回的笔记标识。
fn parse_id(id: &str) -> Result<Id, NoteResult> {
    Id::parse(id).map_err(|_| NoteResult {
        ok: false,
        code: Some("INVALID_ID".to_owned()),
        hint: Some("笔记标识无效。".to_owned()),
        value: None,
    })
}

/// 列出未删除的笔记，按最近修改倒序。
///
/// `limit = 0` 时使用默认值 50（服务端仓储层还有 500 的硬上限）。
#[must_use]
pub fn notes_list(include_deleted: bool, limit: u32) -> NoteResult {
    let query = NoteQuery {
        include_deleted,
        limit,
        ..NoteQuery::default()
    };
    match with_core(|core| core.list_notes(&query)) {
        Ok(notes) => {
            let mut summaries: Vec<NoteSummary> = notes.iter().map(summary_of).collect();
            // 最近修改的排在最前：界面最常用的是"接着上次写"
            summaries.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
            NoteResult::ok(NotePayload {
                notes: summaries,
                ..NotePayload::default()
            })
        }
        Err(failure) => failure,
    }
}

/// 创建一篇空笔记。
#[must_use]
pub fn notes_create(title: &str, at_ms: i64) -> NoteResult {
    // 设备标识与写入**必须在同一次加锁内**完成。
    // 反例（曾写成这样，会死锁）：先 with_core(device_id) 取设备标识，再 with_core(create)。
    // 两次调用都要读同一把 RwLock；同一线程嵌套获取读锁时，若有写者在排队，
    // 后一次读锁会永久等待 —— 表现为"点了新建笔记界面卡住"。
    // 因此 `with_core` 的闭包约定：**内部不得再调用 with_core**，要什么一次取完。
    match with_core(|core| {
        let device = core.device_id()?;
        core.create_note_with_document(None, title, Document::empty(at_ms), &device, at_ms)
    }) {
        Ok(note) => NoteResult::ok(NotePayload {
            note: Some(summary_of(&note)),
            ..NotePayload::default()
        }),
        Err(failure) => failure,
    }
}

/// 读取一篇笔记的元数据与纯文本内容。
#[must_use]
pub fn notes_read(id: &str) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| {
        let note = core.get_note(&parsed)?;
        let document = core.get_note_document(&parsed)?;
        Ok((note, document))
    }) {
        Ok((note, document)) => NoteResult::ok(NotePayload {
            note: Some(summary_of(&note)),
            text: Some(document_to_text(&document)),
            notes: Vec::new(),
        }),
        Err(failure) => failure,
    }
}

/// 保存一篇笔记的内容（自动递增修订号并追加修订记录，铁律 T6）。
#[must_use]
pub fn notes_save(id: &str, text: &str, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    let document = text_to_document(text, at_ms);

    // 摘要取首行，便于列表展示
    let summary: String = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("")
        .chars()
        .take(120)
        .collect();

    // 同 notes_create：读设备标识与写入必须一次加锁完成，避免嵌套读锁（见那里的注释）。
    match with_core(|core| {
        let device = core.device_id()?;
        let mut note = core.get_note(&parsed)?;
        note.set_summary(summary)?;
        core.save_note(note, document, &device, at_ms)
    }) {
        Ok(note) => NoteResult::ok(NotePayload {
            note: Some(summary_of(&note)),
            ..NotePayload::default()
        }),
        Err(failure) => failure,
    }
}

/// 把一篇笔记移入回收站（软删除，铁律 T7）。
#[must_use]
pub fn notes_delete(id: &str, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.delete_note(&parsed, at_ms)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 从回收站恢复一篇笔记。
#[must_use]
pub fn notes_restore(id: &str, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.restore_note(&parsed, at_ms)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 笔记总数（不含回收站）。
#[must_use]
pub fn notes_count() -> i64 {
    match with_core(|core| core.note_count()) {
        Ok(count) => count,
        Err(_) => -1,
    }
}

/// 一条修订记录在界面上的表示。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionEntry {
    /// 修订标识。
    pub id: String,
    /// 对应的笔记版本号。
    pub version: i64,
    /// 父修订标识（首条修订为 `None`）；用于验证历史链完整。
    pub parent_id: Option<String>,
    /// 产生该修订的设备标识。
    pub device_id: String,
    /// 操作类型，如 `"note.update"`。
    pub operation: String,
    /// 记录时间（UTC 毫秒）。
    pub created_at_ms: i64,
}

/// 某篇笔记的修订历史，**按版本倒序**（最新在前）。
///
/// ## 为什么把它暴露到界面
///
/// 铁律 T6 要求"每一次修改必须可追踪"。暴露它有两个直接价值：
///
/// 1. **可验证**：跨语言测试能断言"无变更的保存不产生修订"（技术债 #11 的
///    关键语义），而不必只相信 Rust 侧的单元测试；
/// 2. **P3 的版本历史面板**会直接消费它。
#[must_use]
pub fn notes_revision_history(id: &str, limit: u32) -> Vec<RevisionEntry> {
    let Ok(parsed) = Id::parse(id) else {
        return Vec::new();
    };
    match with_core(|core| core.revision_history(&parsed, limit)) {
        Ok(revisions) => revisions
            .into_iter()
            .map(|revision| RevisionEntry {
                id: revision.id.to_string(),
                version: revision.version,
                parent_id: revision.parent_revision_id.map(|parent| parent.to_string()),
                device_id: revision.device_id,
                operation: revision.operation,
                created_at_ms: revision.created_at_ms,
            })
            .collect(),
        Err(_) => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000_000;

    /// 串行化"会动到全局引擎"的测试。锁本身定义在模块级
    /// （见 [`engine_lock_for_tests`]），因为 `branding` 的测试也要用同一把。
    fn engine_lock() -> std::sync::MutexGuard<'static, ()> {
        crate::api::notes::test_support::engine_lock()
    }

    /// 每个测试用独立数据目录 + 独占引擎。
    fn fresh_engine() -> (tempfile::TempDir, std::sync::MutexGuard<'static, ()>) {
        let guard = engine_lock();
        let dir = tempfile::tempdir().expect("tempdir");
        let status = engine_start(&dir.path().to_string_lossy());
        assert!(status.ready, "引擎应启动成功：{:?}", status.message);
        (dir, guard)
    }

    #[test]
    fn unstarted_engine_reports_structured_failure() {
        // 引擎未启动时的错误结构。这里直接验证构造函数本身，
        // 因为"未启动"状态在进程级单例下依赖测试执行顺序，不可靠。
        let failure = NoteResult::not_started();
        assert!(!failure.ok);
        assert_eq!(failure.code.as_deref(), Some("ENGINE_NOT_STARTED"));
        assert!(failure.hint.is_some());
        assert!(failure.value.is_none());
    }

    #[test]
    fn note_lifecycle_round_trips_through_text() {
        let (_dir, _guard) = fresh_engine();

        let created = notes_create("第一篇", NOW);
        assert!(created.ok, "创建失败：{:?}", created.hint);
        let note = created.value.expect("payload").note.expect("note");
        assert_eq!(note.title, "第一篇");
        assert_eq!(note.version, 1);

        let saved = notes_save(&note.id, "第一行\n第二行", NOW + 1000);
        assert!(saved.ok, "保存失败：{:?}", saved.hint);
        let saved_note = saved.value.expect("payload").note.expect("note");
        assert_eq!(saved_note.version, 2, "保存必须递增修订号（铁律 T6）");
        assert_eq!(saved_note.summary, "第一行", "摘要应取首行");

        let read = notes_read(&note.id);
        assert!(read.ok);
        let text = read.value.expect("payload").text.expect("text");
        assert_eq!(text, "第一行\n第二行", "内容必须能原样读回");

        assert!(notes_count() >= 1);
    }

    #[test]
    fn invalid_id_is_reported_not_panicking() {
        let (_dir, _guard) = fresh_engine();
        let failure = notes_read("not-a-uuid");
        assert!(!failure.ok);
        assert_eq!(failure.code.as_deref(), Some("INVALID_ID"));
    }

    #[test]
    fn missing_note_reports_not_found() {
        let (_dir, _guard) = fresh_engine();
        let failure = notes_read(&Id::new().to_string());
        assert!(!failure.ok);
        assert_eq!(failure.code.as_deref(), Some("NOT_FOUND"));
        assert!(failure.hint.is_some(), "必须给用户可读提示（铁律 E2）");
    }

    #[test]
    fn delete_moves_note_out_of_default_list_and_restore_brings_it_back() {
        let (_dir, _guard) = fresh_engine();

        let created = notes_create("待删除", NOW);
        assert!(created.ok, "创建失败：{:?}", created.hint);
        let note = created.value.expect("payload").note.expect("note");

        let listed = notes_list(false, 0);
        let ids: Vec<String> = listed
            .value
            .expect("payload")
            .notes
            .into_iter()
            .map(|item| item.id)
            .collect();
        assert!(ids.contains(&note.id), "新建笔记应出现在列表中");

        assert!(notes_delete(&note.id, NOW + 1).ok);
        let after_delete = notes_list(false, 0);
        let ids_after: Vec<String> = after_delete
            .value
            .expect("payload")
            .notes
            .into_iter()
            .map(|item| item.id)
            .collect();
        assert!(
            !ids_after.contains(&note.id),
            "已删除笔记不应出现在默认列表"
        );

        // 但带 include_deleted 时仍能看到（软删除，铁律 T7）
        let with_deleted = notes_list(true, 0);
        let ids_all: Vec<String> = with_deleted
            .value
            .expect("payload")
            .notes
            .into_iter()
            .map(|item| item.id)
            .collect();
        assert!(ids_all.contains(&note.id), "软删除的笔记必须仍可查询到");

        assert!(notes_restore(&note.id, NOW + 2).ok);
        assert!(notes_read(&note.id).ok, "恢复后应能正常读取");
    }

    #[test]
    fn title_too_long_is_a_validation_error() {
        let (_dir, _guard) = fresh_engine();
        let long = "汉".repeat(nested_model::MAX_TITLE_CHARS + 1);
        let failure = notes_create(&long, NOW);
        assert!(!failure.ok);
        assert_eq!(failure.code.as_deref(), Some("VALIDATION_ERROR"));
    }

    #[test]
    fn empty_text_saves_as_empty_document() {
        let (_dir, _guard) = fresh_engine();
        let created = notes_create("空内容", NOW);
        assert!(created.ok, "创建失败：{:?}", created.hint);
        let note = created.value.expect("payload").note.expect("note");

        let saved = notes_save(&note.id, "", NOW + 1);
        assert!(saved.ok, "保存失败：{:?}", saved.hint);

        let read = notes_read(&note.id);
        let text = read.value.expect("payload").text.expect("text");
        assert_eq!(text, "", "空内容应读回空字符串而不是报错");
    }

    #[test]
    fn data_survives_engine_restart() {
        // 这是"重启后还在"的自动化版本：重新 engine_start 同一个目录，
        // 之前写入的笔记必须仍然可读（铁律 T1：数据不丢）。
        let guard = engine_lock();
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().to_string_lossy().to_string();

        assert!(engine_start(&path).ready);
        let created = notes_create("持久化", NOW);
        let note = created.value.expect("payload").note.expect("note");
        assert!(notes_save(&note.id, "重启前的正文", NOW + 1).ok);

        // 模拟重启：用同一目录重新启动引擎
        assert!(engine_start(&path).ready);
        let read = notes_read(&note.id);
        assert!(read.ok, "重启后笔记应仍可读：{:?}", read.hint);
        assert_eq!(
            read.value.expect("payload").text.expect("text"),
            "重启前的正文",
            "重启后内容必须完整（铁律 T1）"
        );

        drop(guard);
    }
}
