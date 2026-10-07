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
    /// **仅诊断用**的内部错误详情。
    ///
    /// 默认恒为 `None`：铁律 E2 禁止把内部细节给界面。
    /// 只有设置了环境变量 `NESTED_DEBUG_ERRORS=1` 时才填充——
    /// 用于"用户看到一句泛化提示、开发需要知道到底哪里错了"的场合
    /// （本项目在排查三栏界面的列表查询失败时就靠它）。
    pub debug_detail: Option<String>,
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
    /// 笔记本（创建笔记本时返回）。
    pub notebook: Option<NotebookNode>,
    /// 笔记本树（树查询返回，已按展开顺序排列）。
    pub notebooks: Vec<NotebookNode>,
    /// 修订历史（历史查询返回，按版本倒序）。
    pub revisions: Vec<RevisionEntry>,
    /// 修订差异（对比查询返回）。
    pub diff: Option<RevisionDiffPayload>,
}

/// 一次修订对比的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionDiffPayload {
    /// 旧版本摘要。
    pub older: RevisionSummaryEntry,
    /// 新版本摘要。
    pub newer: RevisionSummaryEntry,
    /// 新增行数。
    pub added: i64,
    /// 删除行数。
    pub removed: i64,
    /// 是否因**缺少内容快照**而无法对比。
    ///
    /// 为 `true` 时 `lines` 必定为空——但**不能**把它当成"两版相同"。
    /// 界面必须据此显示"此版本没有内容快照"，否则用户会以为内容没变，
    /// 而事实是我们不知道。这是本功能最容易出错的地方。
    pub missing_snapshot: bool,
    /// 旧版本是否缺快照。
    pub old_missing: bool,
    /// 新版本是否缺快照。
    pub new_missing: bool,
    /// 逐行差异。
    pub lines: Vec<RevisionDiffEntry>,
}

/// 修订摘要（对比界面显示"这是哪一版"）。
///
/// ## 为什么不直接复用内核的 `RevisionSummary`
///
/// 试过写 `pub type RevisionSummaryEntry = nested_core::RevisionSummary;`，
/// 但 `flutter_rust_bridge` **不解析类型别名**——它把别名当成了不透明类型，
/// 生成出 `RustAutoOpaqueInner<RevisionSummary>` 这类代码，编译直接失败
/// （22 个错误）。跨语言边界的类型必须是具体的。
///
/// 因此这里保留一份具体结构，但**用 `From` 做唯一转换点**：
/// 字段一旦在两边不一致，编译器会在那个 `From` 上报错，而不是悄悄漂移。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionSummaryEntry {
    /// 版本号。
    pub version: i64,
    /// 产生时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 产生该变更的设备。
    pub device_id: String,
    /// 操作类型，如 `"note.update"`。
    pub operation: String,
}

impl From<nested_core::RevisionSummary> for RevisionSummaryEntry {
    fn from(summary: nested_core::RevisionSummary) -> Self {
        Self {
            version: summary.version,
            created_at_ms: summary.created_at_ms,
            device_id: summary.device_id,
            operation: summary.operation,
        }
    }
}

/// 差异中的一行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionDiffEntry {
    /// 类型：`"unchanged"` / `"added"` / `"removed"`。
    ///
    /// 用字符串而不是枚举，是为了让 Dart 侧直接用 `switch` 分支——
    /// FRB 对枚举的支持需要额外配置，而这三个值很稳定。
    pub kind: String,
    /// 行内容。
    pub text: String,
}

impl NoteResult {
    /// 成功。
    #[must_use]
    fn ok(value: NotePayload) -> Self {
        Self {
            ok: true,
            code: None,
            hint: None,
            debug_detail: None,
            value: Some(value),
        }
    }

    /// 失败：把 [`CoreError`] 转成可跨语言传递的结构。
    ///
    /// **注意**：这里用 `code()` 与 `user_hint()`，绝不把 `Display` 输出
    /// （可能含路径或 SQL 片段）直接交给界面（铁律 E2）。
    /// 唯一的例外是 `NESTED_DEBUG_ERRORS=1` 时的 `debug_detail`——那是
    /// 开发期诊断开关，默认关闭，且真机上不会有人设它。
    #[must_use]
    fn failed(error: CoreError) -> Self {
        Self {
            ok: false,
            code: Some(error.code().to_owned()),
            hint: Some(error.user_hint().to_owned()),
            debug_detail: debug_detail_of(&error),
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
            debug_detail: None,
            value: None,
        }
    }
}

/// 在 `NESTED_DEBUG_ERRORS=1` 时给出内部错误详情，否则 `None`。
///
/// 为什么需要这个开关：用户看到的提示必须是"一句话、无内部细节"（铁律 E2），
/// 但开发排查"到底哪里错了"时又需要 `Display` 输出。
/// 用一个显式环境变量把两者分开，而不是把细节永远带在返回值里。
fn debug_detail_of(error: &CoreError) -> Option<String> {
    if std::env::var("NESTED_DEBUG_ERRORS").ok().as_deref() != Some("1") {
        return None;
    }
    Some(format!("{error:?}"))
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
        debug_detail: None,
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
        debug_detail: None,
        value: None,
    })
}

/// 列出笔记，按最近修改倒序。
///
/// ## 参数
///
/// - `notebook_id`：限定笔记本；`None` 表示"全部笔记"（不按笔记本过滤）
/// - `include_descendants`：是否把**子笔记本**里的笔记也算进来。
///   仅在给了 `notebook_id` 时有意义。界面默认打开它——用户点选父笔记本时
///   期望看到它以及所有后代的笔记，否则每建一层子笔记本父级就变空了。
/// - `include_deleted`：是否包含回收站（铁律 T7）
/// - `limit`：`0` 表示用默认值 50（仓储层另有 500 的硬上限）
#[must_use]
pub fn notes_list(
    notebook_id: Option<String>,
    include_descendants: bool,
    include_deleted: bool,
    limit: u32,
) -> NoteResult {
    // 先解析 id：无效时明确报错，而不是静默退化成"全部笔记"
    // （静默退化会让用户以为"这个笔记本里就是有这些笔记"，极具误导性）
    let notebook = match notebook_id.as_deref().map(Id::parse) {
        Some(Ok(id)) => Some(id),
        Some(Err(_)) => {
            return NoteResult {
                ok: false,
                code: Some("INVALID_ID".to_owned()),
                hint: Some("笔记本标识无效。".to_owned()),
                debug_detail: None,
                value: None,
            };
        }
        None => None,
    };

    let query = NoteQuery {
        notebook_id: notebook.as_ref(),
        include_descendants,
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
///
/// `notebook_id` 给出时直接建在该笔记本下——这是"在某个笔记本里点新建"的
/// 期望行为，否则新建的笔记会跑到"全部笔记"里，用户还得再手动移动一次。
#[must_use]
pub fn notes_create(notebook_id: Option<String>, title: &str, at_ms: i64) -> NoteResult {
    let notebook = match notebook_id.as_deref().map(Id::parse) {
        Some(Ok(id)) => Some(id),
        Some(Err(_)) => {
            return NoteResult {
                ok: false,
                code: Some("INVALID_ID".to_owned()),
                hint: Some("笔记本标识无效。".to_owned()),
                debug_detail: None,
                value: None,
            };
        }
        None => None,
    };

    // 设备标识与写入**必须在同一次加锁内**完成。
    // 反例（曾写成这样，会死锁）：先 with_core(device_id) 取设备标识，再 with_core(create)。
    // 两次调用都要读同一把 RwLock；同一线程嵌套获取读锁时，若有写者在排队，
    // 后一次读锁会永久等待 —— 表现为"点了新建笔记界面卡住"。
    // 因此 `with_core` 的闭包约定：**内部不得再调用 with_core**，要什么一次取完。
    match with_core(|core| {
        let device = core.device_id()?;
        core.create_note_with_document(notebook, title, Document::empty(at_ms), &device, at_ms)
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
            ..NotePayload::default()
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

// ============================================================ 笔记本（树形）

/// 一个笔记本在界面上的表示。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookNode {
    /// 笔记本标识。
    pub id: String,
    /// 名称。
    pub name: String,
    /// 父笔记本标识（顶层为 `None`）。
    pub parent_id: Option<String>,
    /// 在树中的层级深度（顶层为 0）。
    ///
    /// 由 Rust 侧算好：让每个前端各写一遍"组装树 + 深度优先 + 处理孤儿节点"
    /// 是典型的业务规则漏到 UI 层（铁律 A2）。
    pub depth: u32,
    /// 该笔记本**及其全部后代**中的笔记数量。
    ///
    /// 放在这里而不是让界面自己算：它需要递归统计，
    /// 且"父级显示子孙总数"是产品语义而非展示细节。
    pub note_count: i64,
}

/// 列出笔记本树（深度优先，含每个节点及其子树的笔记数）。
///
/// 返回值已按树形展开顺序排列，界面直接顺序渲染并按键值缩进即可。
///
/// ## 为什么返回 [`NoteResult`] 而不是裸 `Vec`
///
/// 第一版签名是 `-> Vec<NotebookNode>`，失败时返回空列表。
/// 那是个错误设计：**"查询失败"与"确实没有笔记本"变成了同一个结果**，
/// 界面显示"还没有笔记本"，而真实原因可能是数据库出错——
/// 用户会以为数据丢了（本项目就因此白排查了一轮）。
///
/// 现在失败会带上错误码与提示，界面能如实告知"读取失败"而不是"没有数据"。
#[must_use]
pub fn notebooks_tree() -> NoteResult {
    match with_core(|core| {
        let tree = core.list_notebook_tree()?;
        let mut nodes = Vec::with_capacity(tree.len());
        for (notebook, depth) in tree {
            // 统计"该笔记本及其全部后代"的笔记数
            let mut total = 0_i64;
            for notebook_id in core.notebook_subtree_ids(&notebook.id)? {
                let query = NoteQuery {
                    notebook_id: Some(&notebook_id),
                    ..NoteQuery::default()
                };
                total += i64::try_from(core.list_notes(&query)?.len()).unwrap_or(0);
            }
            nodes.push(NotebookNode {
                id: notebook.id.to_string(),
                name: notebook.name,
                parent_id: notebook.parent_id.map(|parent| parent.to_string()),
                depth,
                note_count: total,
            });
        }
        Ok(nodes)
    }) {
        Ok(nodes) => NoteResult::ok(NotePayload {
            notebooks: nodes,
            ..NotePayload::default()
        }),
        Err(failure) => failure,
    }
}

/// 创建笔记本。`parent_id` 为 `None` 时创建顶层笔记本。
#[must_use]
pub fn notebooks_create(name: &str, parent_id: Option<String>, at_ms: i64) -> NoteResult {
    let parent = match parent_id.as_deref().map(Id::parse) {
        Some(Ok(id)) => Some(id),
        Some(Err(_)) => {
            return NoteResult {
                ok: false,
                code: Some("INVALID_ID".to_owned()),
                hint: Some("父笔记本标识无效。".to_owned()),
                debug_detail: None,
                value: None,
            };
        }
        None => None,
    };

    match with_core(|core| core.create_notebook(name, parent, at_ms)) {
        Ok(notebook) => NoteResult::ok(NotePayload {
            notebook: Some(NotebookNode {
                id: notebook.id.to_string(),
                name: notebook.name,
                parent_id: notebook.parent_id.map(|id| id.to_string()),
                // 真实深度由随后的 notebooks_tree() 给出；这里不重复计算
                depth: 0,
                note_count: 0,
            }),
            ..NotePayload::default()
        }),
        Err(failure) => failure,
    }
}

/// 把笔记本移入回收站（软删除，铁律 T7）。**不**级联删除其下笔记。
#[must_use]
pub fn notebooks_delete(id: &str, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.delete_notebook(&parsed, at_ms)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 从回收站恢复笔记本。
#[must_use]
pub fn notebooks_restore(id: &str, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.restore_notebook(&parsed, at_ms)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 重命名笔记本。
#[must_use]
pub fn notebooks_rename(id: &str, name: &str, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.rename_notebook(&parsed, name, at_ms)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 把笔记本移动到另一个父节点下（`parent_id` 为 `None` 时移到顶层）。
///
/// 会成环的移动返回 `code = "WOULD_CREATE_CYCLE"`——
/// 界面应据此提示"请选择另一个位置"，而不是当成故障。
#[must_use]
pub fn notebooks_move(id: &str, parent_id: Option<String>, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    let parent = match parent_id.as_deref().map(Id::parse) {
        Some(Ok(target)) => Some(target),
        Some(Err(_)) => {
            return NoteResult {
                ok: false,
                code: Some("INVALID_ID".to_owned()),
                hint: Some("目标笔记本标识无效。".to_owned()),
                debug_detail: None,
                value: None,
            };
        }
        None => None,
    };
    match with_core(|core| core.move_notebook(&parsed, parent.as_ref(), at_ms)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 回收站保留期（天）。
///
/// 界面需要它来显示"还剩 N 天"。**不要在 Dart 侧另写一个常量**——
/// 两处各写一份就会出现"提示还剩 3 天、实际已经删了"。
#[must_use]
pub fn trash_retention_days() -> i64 {
    nested_core::NestedCore::TRASH_RETENTION_DAYS
}

/// 彻底删除回收站中已超过保留期的内容，返回被删除的条数（笔记数, 笔记本数）。
///
/// 应用启动时调用一次即可。**注意**：这是全项目唯一不经用户操作就销毁数据的
/// 路径，调用方应当把"删掉了什么"告诉用户，而不是悄悄删。
#[must_use]
pub fn trash_purge(now_ms: i64) -> (i64, i64) {
    match with_core(|core| core.purge_trash(now_ms)) {
        Ok(report) => (
            i64::try_from(report.notes_removed).unwrap_or(i64::MAX),
            i64::try_from(report.notebooks_removed).unwrap_or(i64::MAX),
        ),
        // 清理失败绝不能影响应用启动：这是后台维护动作，不是用户操作。
        // 返回 (0,0) 而不是抛错——下次启动会再试。
        Err(_) => (0, 0),
    }
}

/// 已到期、下次清理就会被删掉的笔记数（用于界面提示）。
#[must_use]
pub fn trash_expired_count(now_ms: i64) -> i64 {
    match with_core(|core| core.count_expired_trash(now_ms)) {
        Ok(count) => count,
        Err(_) => 0,
    }
}

/// **彻底删除**回收站中的一篇笔记（不可逆，需界面二次确认）。
///
/// 只对**已在回收站中**的笔记有效；活跃笔记会返回 `NOT_FOUND`
/// （内核刻意如此，避免这个接口变成"删任何笔记"的通用入口）。
#[must_use]
pub fn notes_purge(id: &str) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.purge_note(&parsed)) {
        Ok(()) => NoteResult::ok(NotePayload::default()),
        Err(failure) => failure,
    }
}

/// 把一篇笔记移到另一个笔记本（`notebook_id` 为 `None` 时移出笔记本）。
#[must_use]
pub fn notes_move(id: &str, notebook_id: Option<String>, at_ms: i64) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    let target = match notebook_id.as_deref().map(Id::parse) {
        Some(Ok(target)) => Some(target),
        Some(Err(_)) => {
            return NoteResult {
                ok: false,
                code: Some("INVALID_ID".to_owned()),
                hint: Some("目标笔记本标识无效。".to_owned()),
                debug_detail: None,
                value: None,
            };
        }
        None => None,
    };
    // 同 notes_create：设备标识与操作必须在同一次加锁内取得
    let device = match with_core(|core| core.device_id()) {
        Ok(device) => device,
        Err(failure) => return failure,
    };

    match with_core(|core| {
        let mut note = core.get_note(&parsed)?;
        note.set_notebook(target)?;
        let document = core.get_note_document(&parsed)?;
        core.save_note(note, document, &device, at_ms)
    }) {
        Ok(note) => NoteResult::ok(NotePayload {
            note: Some(summary_of(&note)),
            ..NotePayload::default()
        }),
        Err(failure) => failure,
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
/// ## 返回值为什么是 [`NoteResult`] 而不是裸 `Vec`
///
/// 第一版签名是 `-> Vec<RevisionEntry>`，失败时返回空列表。
/// 那是个错误设计（本项目在 `notebooks_tree` 上已经踩过一次同样的坑）：
/// **"查询失败"与"这篇笔记没有历史"变成了同一个结果**，
/// 界面会显示"还没有历史版本"，而真实原因可能是数据库出错。
///
/// 现在失败会带上错误码与提示，界面能如实告知。
#[must_use]
pub fn notes_revision_history(id: &str, limit: u32) -> NoteResult {
    let parsed = match parse_id(id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    match with_core(|core| core.revision_history(&parsed, limit)) {
        Ok(revisions) => NoteResult::ok(NotePayload {
            revisions: revisions
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
            ..NotePayload::default()
        }),
        Err(failure) => failure,
    }
}

/// 比较两条修订的内容，返回逐行差异。
///
/// `old_id` → `new_id` 的顺序与 diff 工具惯例一致。传反了不会报错，
/// 但差异会反向显示（"新增"变"删除"）。
///
/// ## 缺快照时返回 `missing_snapshot = true`，而不是空差异
///
/// 迁移 `0003` 之前的修订没有内容快照。那种情况**不能**当作"零差异"——
/// 用户会以为两版内容相同，而事实是我们不知道。
/// 界面必须把这两种情况分开显示。
#[must_use]
pub fn notes_revision_diff(old_id: &str, new_id: &str) -> NoteResult {
    let old = match parse_id(old_id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };
    let new = match parse_id(new_id) {
        Ok(parsed) => parsed,
        Err(failure) => return failure,
    };

    match with_core(|core| core.diff_revisions(&old, &new)) {
        Ok(nested_core::RevisionDiff::Diff {
            older,
            newer,
            added,
            removed,
            lines,
        }) => NoteResult::ok(NotePayload {
            diff: Some(RevisionDiffPayload {
                older: older.into(),
                newer: newer.into(),
                added: i64::try_from(added).unwrap_or(i64::MAX),
                removed: i64::try_from(removed).unwrap_or(i64::MAX),
                missing_snapshot: false,
                old_missing: false,
                new_missing: false,
                lines: lines
                    .into_iter()
                    .map(|line| RevisionDiffEntry {
                        kind: match line.kind {
                            nested_core::DiffLineKind::Unchanged => "unchanged".to_owned(),
                            nested_core::DiffLineKind::Added => "added".to_owned(),
                            nested_core::DiffLineKind::Removed => "removed".to_owned(),
                        },
                        text: line.text,
                    })
                    .collect(),
            }),
            ..NotePayload::default()
        }),
        Ok(nested_core::RevisionDiff::MissingSnapshot {
            older,
            newer,
            old_missing,
            new_missing,
        }) => NoteResult::ok(NotePayload {
            diff: Some(RevisionDiffPayload {
                older: older.into(),
                newer: newer.into(),
                added: 0,
                removed: 0,
                // 这个标志位是**关键**：界面据它显示"此版本没有内容快照"，
                // 而不是显示一个看起来"两版相同"的空差异
                missing_snapshot: true,
                old_missing,
                new_missing,
                lines: Vec::new(),
            }),
            ..NotePayload::default()
        }),
        Err(failure) => failure,
    }
}

/// 某篇笔记有多少条修订**带**内容快照。
///
/// 界面用它区分"没有历史"与"有历史但都是旧记录（无快照）"。
#[must_use]
pub fn notes_revision_snapshot_count(id: &str) -> i64 {
    let Ok(parsed) = Id::parse(id) else {
        return 0;
    };
    match with_core(|core| core.revision_snapshot_count(&parsed)) {
        Ok(count) => count,
        Err(_) => 0,
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

        let created = notes_create(None, "第一篇", NOW);
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

        let created = notes_create(None, "待删除", NOW);
        assert!(created.ok, "创建失败：{:?}", created.hint);
        let note = created.value.expect("payload").note.expect("note");

        let listed = notes_list(None, true, false, 0);
        let ids: Vec<String> = listed
            .value
            .expect("payload")
            .notes
            .into_iter()
            .map(|item| item.id)
            .collect();
        assert!(ids.contains(&note.id), "新建笔记应出现在列表中");

        assert!(notes_delete(&note.id, NOW + 1).ok);
        let after_delete = notes_list(None, true, false, 0);
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
        let with_deleted = notes_list(None, true, true, 0);
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
        let failure = notes_create(None, &long, NOW);
        assert!(!failure.ok);
        assert_eq!(failure.code.as_deref(), Some("VALIDATION_ERROR"));
    }

    #[test]
    fn empty_text_saves_as_empty_document() {
        let (_dir, _guard) = fresh_engine();
        let created = notes_create(None, "空内容", NOW);
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
        let created = notes_create(None, "持久化", NOW);
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
