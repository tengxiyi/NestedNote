//! 内核对外 API（Domain Service 层）。
//!
//! 这是 Flutter 唯一被允许调用的入口（铁律 A1/A3）：
//! 只暴露**业务语义**操作，不暴露 SQL、表结构、行 ID 之类的实现细节。

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nested_db::NoteQuery;
use nested_db::repositories::{notebooks, notes, revisions, tags};
use nested_db::{Database, DbError};
use nested_model::{Attachment, Block, Document, Id, Note, Notebook, Tag};

use crate::error::{CoreError, CoreResult};

/// 设备标识为空的兜底值。
///
/// 正常情况下 `nested-core` 的调用方（Flutter 层）会在首次启动时生成并持久化
/// 真实设备 ID（见 `nested_sync::DEVICE_ID_SETTING_KEY`）。这里保留一个显式兜底，
/// 使 CLI 与测试无需先走设备注册流程。
pub const UNKNOWN_DEVICE_ID: &str = "unknown-device";

/// `settings` 表中存放本设备标识的键名。
///
/// 取值必须与 `nested_sync::DEVICE_ID_SETTING_KEY` 一致。这里重复定义一个常量，
/// 是为了避免 `nested-core` 为了一个字符串而依赖同步引擎（分层更干净）。
pub const DEVICE_ID_SETTING_KEY: &str = "device.id";

/// 一次回收站清理的结果。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TrashPurgeReport {
    /// 被彻底删除的笔记数。
    pub notes_removed: u64,
    /// 被彻底删除的笔记本数。
    pub notebooks_removed: u64,
}

impl TrashPurgeReport {
    /// 本次是否真的删掉了东西。
    ///
    /// 调用方（启动时的清理）用它决定**要不要打扰用户**：
    /// 什么都没删还弹一句提示，是纯噪音，而且会让人以为出了事。
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.notes_removed == 0 && self.notebooks_removed == 0
    }
}

/// 修订的摘要信息（用于对比界面显示"这是哪一版"）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionSummary {
    /// 版本号。
    pub version: i64,
    /// 产生时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 产生该变更的设备。
    pub device_id: String,
    /// 操作类型，如 `note.update`。
    pub operation: String,
}

impl From<&nested_model::Revision> for RevisionSummary {
    fn from(revision: &nested_model::Revision) -> Self {
        Self {
            version: revision.version,
            created_at_ms: revision.created_at_ms,
            device_id: revision.device_id.clone(),
            operation: revision.operation.clone(),
        }
    }
}

/// 差异中一行的类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffLineKind {
    /// 两版都有。
    Unchanged,
    /// 新增。
    Added,
    /// 删除。
    Removed,
}

/// 差异中的一行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionDiffLine {
    /// 类型。
    pub kind: DiffLineKind,
    /// 行内容。
    pub text: String,
}

/// 两条修订的对比结果。
///
/// ## 为什么"缺快照"必须是一个独立变体
///
/// 迁移 `0003` 之前的修订没有内容快照。若把它们当成"零差异"返回，
/// 用户会以为"这两版内容一样"——而事实是**我们不知道**。
/// 把"未知"呈现为"相同"是会误导人的错误，因此做成独立变体，
/// 界面无法把它与真正的"无差异"混为一谈。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevisionDiff {
    /// 成功比出差异。
    Diff {
        /// 旧版本摘要。
        old: RevisionSummary,
        /// 新版本摘要。
        new: RevisionSummary,
        /// 新增行数。
        added: usize,
        /// 删除行数。
        removed: usize,
        /// 逐行差异。
        lines: Vec<RevisionDiffLine>,
    },
    /// 至少一侧没有内容快照（迁移 `0003` 之前的历史修订）。
    MissingSnapshot {
        /// 旧版本摘要。
        old: RevisionSummary,
        /// 新版本摘要。
        new: RevisionSummary,
        /// 旧版本是否缺快照。
        old_missing: bool,
        /// 新版本是否缺快照。
        new_missing: bool,
    },
}

/// 内核句柄。
#[derive(Debug)]
pub struct NestedCore {
    database: Database,
    /// 附件存储与元数据的协调者。
    ///
    /// `None` 表示内存库：附件必须落在真实目录里，而内存库没有数据目录。
    /// 此时附件相关操作返回 [`CoreError::Config`] 并说明原因，
    /// 而不是悄悄写到一个临时位置（那会让测试与真实行为不一致）。
    attachments: Option<crate::attachments::AttachmentService>,
    /// 本设备标识的缓存。
    ///
    /// ## 为什么需要它
    ///
    /// 每次写入都要往同步队列里记"是哪台设备产生的变更"（铁律 T3）。
    /// 设备标识在首次启动时生成并持久化到 `settings`（键为 [`DEVICE_ID_SETTING_KEY`]），
    /// 此后不再变化；缓存在这里避免每次写入都多读一次设置表。
    ///
    /// 若表中尚无设备标识（CLI 直接建库、测试环境），使用 [`UNKNOWN_DEVICE_ID`] 兜底
    /// 并**不擅自落库**——生成设备标识属于应用启动流程的职责，不该是内核的副作用。
    device_id_cache: Mutex<Option<String>>,
}

impl NestedCore {
    /// 在指定数据目录下打开（或创建）内核。
    ///
    /// 数据目录内会创建 `nested.db` 与 `attachments/`（内容寻址存储）。
    ///
    /// # Errors
    ///
    /// - 目录不可创建 → [`CoreError::Config`]
    /// - 数据库无法打开或迁移失败 → [`CoreError::Database`]
    pub fn open(data_dir: impl AsRef<Path>) -> CoreResult<Self> {
        let data_dir = data_dir.as_ref();
        std::fs::create_dir_all(data_dir)
            .map_err(|error| CoreError::Config(format!("无法创建数据目录：{error}")))?;
        let path = data_dir.join(crate::branding::DATABASE_FILE);
        let database = Database::open(&path)?;
        Ok(Self {
            database,
            attachments: Some(crate::attachments::AttachmentService::new(data_dir)),
            device_id_cache: Mutex::new(None),
        })
    }

    /// 在内存中打开内核（测试与 CLI 快速验证用）。
    ///
    /// 附件功能在此模式下不可用（没有数据目录），调用会返回 [`CoreError::Config`]。
    /// 需要测附件时请用 [`NestedCore::open`] 配合临时目录。
    ///
    /// # Errors
    ///
    /// 迁移失败时返回 [`CoreError::Database`]。
    pub fn open_in_memory() -> CoreResult<Self> {
        Ok(Self {
            database: Database::open_in_memory()?,
            attachments: None,
            device_id_cache: Mutex::new(None),
        })
    }

    /// 本设备标识（用于同步队列记录变更来源，铁律 T3）。
    ///
    /// 解析顺序：内存缓存 → `settings` 表 → [`UNKNOWN_DEVICE_ID`]。
    ///
    /// # Errors
    ///
    /// 读取设置表失败时返回 [`CoreError::Database`]。
    pub fn device_id(&self) -> CoreResult<String> {
        if let Ok(cache) = self.device_id_cache.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }
        let stored = self.database.setting(DEVICE_ID_SETTING_KEY)?;
        let resolved = stored.unwrap_or_else(|| UNKNOWN_DEVICE_ID.to_owned());
        if let Ok(mut cache) = self.device_id_cache.lock() {
            *cache = Some(resolved.clone());
        }
        Ok(resolved)
    }

    /// 底层数据库句柄（仅供 CLI 与诊断使用；**UI 层禁止**直接使用，铁律 A2）。
    #[must_use]
    pub const fn database(&self) -> &Database {
        &self.database
    }

    /// 数据库文件路径（内存库为 `None`）。
    #[must_use]
    pub fn database_path(&self) -> Option<PathBuf> {
        self.database.path().map(Path::to_path_buf)
    }

    /// 当前 schema 版本。
    ///
    /// # Errors
    ///
    /// 读取失败时返回 [`CoreError::Database`]。
    pub fn schema_version(&self) -> CoreResult<u32> {
        Ok(self.database.schema_version()?)
    }

    /// 数据库完整性自检。
    ///
    /// # Errors
    ///
    /// 校验失败时返回 [`CoreError::Database`]（含具体细节）。
    pub fn check_integrity(&self) -> CoreResult<()> {
        Ok(self.database.check_integrity()?)
    }

    /// 就绪自检：返回逐项检查结果，供 CLI `doctor` 与 UI 首屏使用。
    ///
    /// 与"进程活着"不同，这里确认的是**依赖可用**（技术文档：`/readyz` 的客户端对应物）。
    #[must_use]
    pub fn readiness(&self) -> Vec<(&'static str, bool)> {
        vec![
            ("database_open", self.database.ping().is_ok()),
            ("schema_current", self.schema_version().is_ok()),
            ("integrity", self.check_integrity().is_ok()),
        ]
    }

    // ---------------------------------------------------------------- 笔记本

    /// 创建笔记本。
    ///
    /// # Errors
    ///
    /// 名称为空或超长 → [`CoreError::Validation`]；写入失败 → [`CoreError::Database`]。
    pub fn create_notebook(
        &self,
        name: impl Into<String>,
        parent_id: Option<Id>,
        at_ms: i64,
    ) -> CoreResult<Notebook> {
        let notebook = Notebook::new(name, parent_id, at_ms)?;
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notebooks::insert(&mut connection, &notebook, &device_id)?;
        Ok(notebook)
    }

    /// 读取笔记本。
    ///
    /// # Errors
    ///
    /// 不存在 → [`CoreError::NotFound`]。
    pub fn get_notebook(&self, id: &Id) -> CoreResult<Notebook> {
        let connection = self.database.connection()?;
        notebooks::get(&connection, id)?.ok_or(CoreError::NotFound { entity: "notebook" })
    }

    /// 列出全部未删除笔记本（**扁平列表**，层级由 `parent_id` 表达）。
    ///
    /// 之所以返回扁平列表而不是嵌套树：树形结构属于**展示问题**，
    /// 由界面按 `parent_id` 组装即可（一次遍历），而扁平列表在跨 FFI 时
    /// 映射更简单、也更方便按需排序。若将来需要"按树展开的顺序"，
    /// 用 [`NestedCore::list_notebook_tree`]。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_notebooks(&self) -> CoreResult<Vec<Notebook>> {
        let connection = self.database.connection()?;
        Ok(notebooks::list_all(&connection)?)
    }

    /// 列出笔记本树（**深度优先**顺序，带层级深度）。
    ///
    /// 返回值是 `(笔记本, 深度)`：深度 0 为顶层，1 为其子级，依此类推。
    ///
    /// ## 为什么需要它
    ///
    /// 界面的左栏是一棵可展开的树。若只给扁平列表，每个前端都要自己写一遍
    /// "按 parent_id 组装 + 深度优先排序 + 处理孤儿节点"的逻辑——这是
    /// 典型的**业务规则漏到 UI 层**（铁律 A2）。因此这里一次算好。
    ///
    /// ## 孤儿节点
    ///
    /// 若某个笔记本的 `parent_id` 指向一个已不存在（或已被物理移除）的节点，
    /// 它会被当作**顶层**处理，从而保证任何笔记本都不会在界面上"消失"。
    /// 数据层的外键本应阻止这种情况，但界面不该依赖"上游一定没错"。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_notebook_tree(&self) -> CoreResult<Vec<(Notebook, u32)>> {
        let all = self.list_notebooks()?;

        // parent_id → 子节点（保持 list_all 的名称排序）
        let mut children: std::collections::HashMap<Option<Id>, Vec<&Notebook>> =
            std::collections::HashMap::new();
        let known: std::collections::HashSet<Id> = all.iter().map(|nb| nb.id).collect();
        for notebook in &all {
            // 父节点不存在时归到顶层（见上方"孤儿节点"）
            let key = match notebook.parent_id {
                Some(parent) if known.contains(&parent) => Some(parent),
                _ => None,
            };
            children.entry(key).or_default().push(notebook);
        }

        let mut out = Vec::with_capacity(all.len());
        // 显式栈做深度优先，避免递归（笔记本层级可能很深）
        let mut stack: Vec<(&Notebook, u32)> = children
            .get(&None)
            .map(|roots| roots.iter().rev().map(|nb| (*nb, 0_u32)).collect())
            .unwrap_or_default();

        while let Some((notebook, depth)) = stack.pop() {
            out.push((notebook.clone(), depth));
            if let Some(kids) = children.get(&Some(notebook.id)) {
                for child in kids.iter().rev() {
                    stack.push((child, depth + 1));
                }
            }
        }
        Ok(out)
    }

    /// 一个笔记本及其**全部后代**的标识（含自身）。
    ///
    /// 用于"删除笔记本时统计影响范围"之类的场景，也便于界面显示
    /// "该笔记本下共有 N 篇笔记"。
    ///
    /// # Errors
    ///
    /// 笔记本不存在 → [`CoreError::NotFound`]。
    pub fn notebook_subtree_ids(&self, root: &Id) -> CoreResult<Vec<Id>> {
        let all = self.list_notebooks()?;
        if !all.iter().any(|notebook| notebook.id == *root) {
            return Err(CoreError::NotFound { entity: "notebook" });
        }

        let mut children: std::collections::HashMap<Id, Vec<Id>> = std::collections::HashMap::new();
        for notebook in &all {
            if let Some(parent) = notebook.parent_id {
                children.entry(parent).or_default().push(notebook.id);
            }
        }

        let mut out = Vec::new();
        let mut stack = vec![*root];
        while let Some(id) = stack.pop() {
            out.push(id);
            if let Some(kids) = children.get(&id) {
                stack.extend(kids.iter().copied());
            }
        }
        Ok(out)
    }

    // ------------------------------------------------------------------ 笔记

    /// 创建笔记（内容为空文档）。
    ///
    /// # Errors
    ///
    /// 标题超长 → [`CoreError::Validation`]。
    pub fn create_note(
        &self,
        notebook_id: Option<Id>,
        title: impl Into<String>,
        at_ms: i64,
    ) -> CoreResult<Note> {
        self.create_note_with_document(
            notebook_id,
            title,
            Document::empty(at_ms),
            UNKNOWN_DEVICE_ID,
            at_ms,
        )
    }

    /// 创建笔记并指定初始内容。
    ///
    /// 元数据、文档、附件引用与修订记录在**同一个事务**中写入（铁律 D1）。
    ///
    /// # Errors
    ///
    /// 标题超长 → [`CoreError::Validation`]；写入失败 → [`CoreError::Database`]。
    pub fn create_note_with_document(
        &self,
        notebook_id: Option<Id>,
        title: impl Into<String>,
        document: Document,
        device_id: &str,
        at_ms: i64,
    ) -> CoreResult<Note> {
        let note = Note::new(notebook_id, title, at_ms)?;
        let mut connection = self.database.connection()?;
        notes::create_with_document(&mut connection, &note, &document, device_id)?;
        Ok(note)
    }

    /// 读取笔记。
    ///
    /// # Errors
    ///
    /// 不存在 → [`CoreError::NotFound`]。
    pub fn get_note(&self, id: &Id) -> CoreResult<Note> {
        let connection = self.database.connection()?;
        notes::get(&connection, id)?.ok_or(CoreError::NotFound { entity: "note" })
    }

    /// 读取笔记内容。
    ///
    /// # Errors
    ///
    /// 内容损坏 → [`CoreError::Database`]（`Corrupt`）。
    pub fn get_note_document(&self, id: &Id) -> CoreResult<Document> {
        let connection = self.database.connection()?;
        Ok(notes::get_document(&connection, id)?)
    }

    /// 按条件列出笔记。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_notes(&self, query: &NoteQuery<'_>) -> CoreResult<Vec<Note>> {
        let connection = self.database.connection()?;
        Ok(notes::list(&connection, query)?)
    }

    /// 保存笔记（元数据 + 内容）。
    ///
    /// ## 修订语义（技术债 #11 已修正）
    ///
    /// - **内容或标题/摘要确有变化**时：递增 `version`、追加一条修订记录、
    ///   往同步队列入队一条 `note.update`。
    /// - **完全无变化**时：**什么都不做**，原样返回传入的笔记。
    ///
    /// 修正前是无条件 `touch()`：即使一个字都没改，保存也会推进版本、写一条修订
    /// 并入队一条同步操作。这有两个实际后果：
    ///
    /// 1. 修订历史被噪声淹没，"哪几次才是真正的修改"无法分辨；
    /// 2. **自动保存无法实现**——每次按键都会产生一条修订与一次同步操作。
    ///
    /// 因此这条语义是编辑器开启自动保存的前提。
    ///
    /// ## 修订父链
    ///
    /// 新修订的 `parent_revision_id` 指向该笔记当前最新的修订，
    /// 从而形成可追溯的历史链（P6 的并发分叉检测依赖它）。
    ///
    /// # Errors
    ///
    /// - 标题/摘要非法 → [`CoreError::Validation`]
    /// - 笔记不存在 → [`CoreError::NotFound`]
    pub fn save_note(
        &self,
        mut note: Note,
        mut document: Document,
        device_id: &str,
        at_ms: i64,
    ) -> CoreResult<Note> {
        note.set_title(note.title.clone())?;
        note.set_summary(note.summary.clone())?;

        let mut connection = self.database.connection()?;

        // 1) 内容是否变化：只比块，不比元信息（见 is_document_unchanged 的说明）
        let content_changed = !notes::is_document_unchanged(&connection, &note.id, &document)?;

        // 2) 元数据是否变化：与库中已有的记录比
        let stored =
            notes::get(&connection, &note.id)?.ok_or(CoreError::NotFound { entity: "note" })?;
        let metadata_changed = stored.title != note.title
            || stored.summary != note.summary
            || stored.notebook_id != note.notebook_id
            || stored.is_pinned != note.is_pinned
            || stored.is_archived != note.is_archived;

        if !content_changed && !metadata_changed {
            // 无变化：不推进版本、不写修订、不入队（这正是修正后的关键行为）。
            // 返回库中的记录而不是传入的 note，避免调用方拿到未落盘的字段。
            tracing::debug!(note_id = %note.id, "保存时内容无变化，跳过修订与入队");
            return Ok(stored);
        }

        // 3) 父链：指向当前最新修订。
        //    这使修订历史成为一条可追溯的链，而不是互不相干的记录
        //    （P6 的并发分叉检测依赖它）。
        let parent_revision_id =
            revisions::latest_for_note(&connection, &note.id)?.map(|revision| revision.id);

        note.touch(at_ms);
        // 文档元信息跟随笔记时间戳，避免出现
        // "笔记说 10:00 改的、内容说 10:05 改的"这种自相矛盾的状态。
        document.align_timestamps(note.created_at_ms, note.updated_at_ms);
        notes::save_with_document(
            &mut connection,
            &note,
            &document,
            device_id,
            parent_revision_id,
        )?;
        Ok(note)
    }

    /// 移入回收站（软删除，铁律 T7）。
    ///
    /// # Errors
    ///
    /// 笔记不存在或已在回收站 → [`CoreError::NotFound`]。
    pub fn delete_note(&self, id: &Id, at_ms: i64) -> CoreResult<()> {
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notes::soft_delete(&mut connection, id, &device_id, at_ms)?;
        Ok(())
    }

    /// 从回收站恢复。
    ///
    /// # Errors
    ///
    /// 笔记不在回收站中 → [`CoreError::NotFound`]。
    pub fn restore_note(&self, id: &Id, at_ms: i64) -> CoreResult<()> {
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notes::restore(&mut connection, id, &device_id, at_ms)?;
        Ok(())
    }

    /// 把笔记本移入回收站（软删除，铁律 T7）。
    ///
    /// ## **不**级联删除其下的笔记
    ///
    /// 级联删除是危险操作：用户删掉一个"看起来是空的"父笔记本，
    /// 结果连带删掉了忘了放在里面的笔记——这类事故不可逆（即使有回收站，
    /// 用户也未必想到去那里找）。
    ///
    /// 因此这里只删除笔记本自身。其下的笔记仍然存在，只是不再出现在
    /// 任何笔记本的列表里；界面应当提示"该笔记本下还有 N 篇笔记"，
    /// 由用户决定怎么处理。这与铁律 T1（数据不可丢）一致：
    /// **宁可留下"孤儿笔记"让用户自己决定，也不要替他做破坏性选择。**
    ///
    /// # Errors
    ///
    /// 笔记本不存在或已在回收站 → [`CoreError::NotFound`]。
    pub fn delete_notebook(&self, id: &Id, at_ms: i64) -> CoreResult<()> {
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notebooks::soft_delete(&mut connection, id, &device_id, at_ms)?;
        Ok(())
    }

    /// 从回收站恢复笔记本。
    ///
    /// # Errors
    ///
    /// 笔记本不在回收站中 → [`CoreError::NotFound`]。
    pub fn restore_notebook(&self, id: &Id, at_ms: i64) -> CoreResult<()> {
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notebooks::restore(&mut connection, id, &device_id, at_ms)?;
        Ok(())
    }

    /// 重命名笔记本。
    ///
    /// # Errors
    ///
    /// 名称为空或超长 → [`CoreError::Validation`]；不存在 → [`CoreError::NotFound`]。
    pub fn rename_notebook(&self, id: &Id, name: impl Into<String>, at_ms: i64) -> CoreResult<()> {
        // 用 `Notebook::new` 复用名称的校验规则，避免两处各写一套（铁律 T4）。
        // 构造出来的探针只用于校验，不写库。
        let probe = Notebook::new(name, None, at_ms)?;

        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notebooks::rename(&mut connection, id, &probe.name, &device_id, at_ms)?;
        Ok(())
    }

    /// 把笔记本移动到另一个父节点下（`new_parent` 为 `None` 表示移到顶层）。
    ///
    /// ## 成环会被拒绝，而不是被数据库接受
    ///
    /// 自引用外键**不阻止**把祖先移到自己的后代下，但那样会让之后所有
    /// 深度优先遍历无限递归（表现为界面卡死，而不是报错）。
    /// 因此仓储层做环检测，这里把结果翻译成 [`CoreError::WouldCreateCycle`]——
    /// 一条**可读的拒绝**，而不是一个看起来像故障的数据库错误。
    ///
    /// # Errors
    ///
    /// - 目标或新父节点不存在 → [`CoreError::NotFound`]
    /// - 会成环 → [`CoreError::WouldCreateCycle`]
    pub fn move_notebook(&self, id: &Id, new_parent: Option<&Id>, at_ms: i64) -> CoreResult<()> {
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        notebooks::move_to_parent(&mut connection, id, new_parent, &device_id, at_ms)?;
        Ok(())
    }

    // ------------------------------------------------------------------ 标签

    /// 创建标签。
    ///
    /// # Errors
    ///
    /// 重名 → [`CoreError::Conflict`]；名称为空 → [`CoreError::Validation`]。
    pub fn create_tag(&self, name: impl Into<String>, at_ms: i64) -> CoreResult<Tag> {
        let tag = Tag::new(name, at_ms)?;
        let device_id = self.device_id()?;
        let mut connection = self.database.connection()?;
        match tags::insert(&mut connection, &tag, &device_id) {
            Ok(()) => Ok(tag),
            Err(DbError::Conflict { .. }) => Err(CoreError::Conflict("标签名称已存在".to_owned())),
            Err(other) => Err(CoreError::Database(other)),
        }
    }

    /// 列出全部标签。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_tags(&self) -> CoreResult<Vec<Tag>> {
        let connection = self.database.connection()?;
        Ok(tags::list_all(&connection)?)
    }

    /// 列出笔记的标签。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_note_tags(&self, note_id: &Id) -> CoreResult<Vec<Tag>> {
        let connection = self.database.connection()?;
        Ok(tags::list_for_note(&connection, note_id)?)
    }

    // ------------------------------------------------------------ 修订对比

    /// 某条修订的内容快照（`None` = 该修订没有快照）。
    ///
    /// **缺失与"空内容"是两回事**：迁移 `0003` 之前的修订没有快照，
    /// 返回 `None`；而"空文档"会返回 `Some(空 Document)`。
    /// 界面必须区分这两者，详见 [`RevisionDiff::MissingSnapshot`]。
    ///
    /// # Errors
    ///
    /// - 修订不存在 → [`CoreError::NotFound`]
    /// - 快照字节损坏 → [`CoreError::Validation`]
    pub fn revision_snapshot(&self, revision_id: &Id) -> CoreResult<Option<Document>> {
        let connection = self.database.connection()?;
        // 先确认修订存在——否则"没有快照"与"没有这条修订"会无法区分
        if revisions::get(&connection, revision_id)?.is_none() {
            return Err(CoreError::NotFound { entity: "revision" });
        }
        match revisions::get_document(&connection, revision_id)? {
            Some(bytes) => Ok(Some(Document::from_bytes(&bytes)?)),
            None => Ok(None),
        }
    }

    /// 比较两条修订的内容。
    ///
    /// ## 顺序约定
    ///
    /// 参数是 `(旧, 新)`，与 diff 工具的惯例一致。传反了不会报错，
    /// 但差异会反向显示（"新增"变"删除"），因此调用方必须注意。
    ///
    /// ## 缺快照时**不返回空差异**
    ///
    /// 迁移 `0003` 之前的修订没有内容快照。那种情况返回
    /// [`RevisionDiff::MissingSnapshot`]，而不是"零差异"——
    /// 后者会让用户以为"这两版一模一样"，而事实是**我们不知道**。
    /// 把"未知"说成"相同"是会误导人的错误。
    ///
    /// # Errors
    ///
    /// - 任一修订不存在 → [`CoreError::NotFound`]
    /// - 快照字节损坏 → [`CoreError::Validation`]
    pub fn diff_revisions(&self, old: &Id, new: &Id) -> CoreResult<RevisionDiff> {
        let old_snapshot = self.revision_snapshot(old)?;
        let new_snapshot = self.revision_snapshot(new)?;

        let (old_revision, new_revision) = {
            let connection = self.database.connection()?;
            let old_revision = revisions::get(&connection, old)?
                .ok_or(CoreError::NotFound { entity: "revision" })?;
            let new_revision = revisions::get(&connection, new)?
                .ok_or(CoreError::NotFound { entity: "revision" })?;
            (old_revision, new_revision)
        };

        match nested_model::DiffOutcome::from_snapshots(
            old_snapshot.as_ref(),
            new_snapshot.as_ref(),
        ) {
            nested_model::DiffOutcome::Diff(diff) => Ok(RevisionDiff::Diff {
                old: RevisionSummary::from(&old_revision),
                new: RevisionSummary::from(&new_revision),
                added: diff.added,
                removed: diff.removed,
                lines: diff
                    .lines
                    .into_iter()
                    .map(|line| RevisionDiffLine {
                        kind: match line.kind {
                            nested_model::DiffKind::Unchanged => DiffLineKind::Unchanged,
                            nested_model::DiffKind::Added => DiffLineKind::Added,
                            nested_model::DiffKind::Removed => DiffLineKind::Removed,
                        },
                        text: line.text,
                    })
                    .collect(),
            }),
            nested_model::DiffOutcome::MissingSnapshot { side } => {
                Ok(RevisionDiff::MissingSnapshot {
                    old: RevisionSummary::from(&old_revision),
                    new: RevisionSummary::from(&new_revision),
                    old_missing: matches!(
                        side,
                        nested_model::DiffSide::Old | nested_model::DiffSide::Both
                    ),
                    new_missing: matches!(
                        side,
                        nested_model::DiffSide::New | nested_model::DiffSide::Both
                    ),
                })
            }
        }
    }

    /// 某篇笔记有多少条修订**带**内容快照。
    ///
    /// 界面用它区分"没有历史"与"历史存在但都是旧记录（无快照）"。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn revision_snapshot_count(&self, note_id: &Id) -> CoreResult<i64> {
        let connection = self.database.connection()?;
        Ok(revisions::count_documents_for_note(&connection, note_id)?)
    }

    // -------------------------------------------------------------- 回收站清理

    /// 回收站保留期（天）。
    ///
    /// ## ⚠ 这是全项目**唯一**会不经用户操作就销毁数据的参数
    ///
    /// 铁律 T1 的原意是"用户数据在任何情况下都不得丢失"。自动清理是这条铁律的
    /// **显式例外**，由产品决定引入（与主流笔记应用一致）。
    ///
    /// 因此：
    /// - 保留期只在这里定义一次，**不要在别处再写一个 15**——
    ///   两处各写一份会出现"提示还剩 3 天、实际已经删了"；
    /// - 想关闭自动清理，把这个值改得极大即可（**不要**去注释掉调用点，
    ///   那会让"自动清理"变成一段死代码，下次没人知道它为什么在）；
    /// - 界面必须显示剩余天数，让不可逆的操作**可预期**。
    pub const TRASH_RETENTION_DAYS: i64 = 15;

    /// 保留期对应的毫秒数。
    #[must_use]
    pub const fn trash_retention_ms() -> i64 {
        Self::TRASH_RETENTION_DAYS * 24 * 60 * 60 * 1000
    }

    /// 彻底删除回收站中**已超过保留期**的笔记与笔记本。
    ///
    /// ## 为什么笔记本要循环删
    ///
    /// 一次清理的依赖链是：笔记先被删 → 笔记本才不再被引用 → 笔记本才能删。
    /// 若笔记本下还有**子笔记本**，子笔记本必须先在**上一轮**被删掉，
    /// 父笔记本才能在这一轮满足条件。所以需要反复扫，直到某一轮
    /// 一个笔记本都删不掉为止。
    ///
    /// 深度学习用户可能建 5 层目录，因此这里不是"扫两遍就够"，
    /// 而是**循环到不动点**（并设了轮数上限，见下）。
    ///
    /// ## 为什么有轮数上限
    ///
    /// 正常情况下每轮都会消耗一层，轮数不会超过树的深度。
    /// 但"正常情况下"不是一个可以依赖的前提——如果哪天有人写出
    /// 让笔记本**引用自身**的 bug，没有上限的循环就变成死循环，
    /// 表现为启动时卡死。上限把它变成一次无害的提前退出。
    ///
    /// # Errors
    ///
    /// 数据库错误 → [`CoreError::Database`]。
    pub fn purge_trash(&self, now_ms: i64) -> CoreResult<TrashPurgeReport> {
        let cutoff = now_ms.saturating_sub(Self::trash_retention_ms());
        let mut report = TrashPurgeReport::default();
        let mut connection = self.database.connection()?;

        // 笔记只有一层，删一遍就到底
        report.notes_removed = notes::purge_deleted_before(&mut connection, cutoff)?;

        // 笔记本要循环到不动点。上限 64 远超任何真实目录深度；
        // 真撞上了说明数据结构出了问题，此时"少删几个空笔记本"远比"启动卡死"好。
        const MAX_PASSES: usize = 64;
        for _ in 0..MAX_PASSES {
            let removed = notebooks::purge_deleted_before(&mut connection, cutoff)?;
            if removed == 0 {
                break;
            }
            report.notebooks_removed += removed;
        }

        Ok(report)
    }

    /// 回收站中还有多少条笔记"已到期、下次清理就会被删"。
    ///
    /// 界面用它显示"已过期，下次启动将清理"。判定条件与
    /// [`Self::purge_trash`] **共用同一个阈值来源**，不会出现两处不一致。
    ///
    /// # Errors
    ///
    /// 数据库错误 → [`CoreError::Database`]。
    pub fn count_expired_trash(&self, now_ms: i64) -> CoreResult<i64> {
        let cutoff = now_ms.saturating_sub(Self::trash_retention_ms());
        let connection = self.database.connection()?;
        Ok(notes::count_purgeable(&connection, cutoff)?)
    }

    /// **彻底删除**回收站中的一篇笔记（用户显式操作，不可逆）。
    ///
    /// ## 这是用户可达的唯一硬删除入口
    ///
    /// 界面上只有回收站菜单会调它，且必须二次确认。
    /// 仓储层额外要求"该笔记已在回收站中"——活跃笔记即便 id 正确也删不掉，
    /// 这样即使将来有人从别处误调用，也不会造成不可恢复的丢失。
    ///
    /// # Errors
    ///
    /// 笔记不存在或**不在回收站中** → [`CoreError::NotFound`]。
    pub fn purge_note(&self, id: &Id) -> CoreResult<()> {
        let mut connection = self.database.connection()?;
        notes::purge_one(&mut connection, id)?;
        Ok(())
    }

    // ------------------------------------------------------------------ 统计

    /// 未删除笔记数量。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn note_count(&self) -> CoreResult<i64> {
        let connection = self.database.connection()?;
        Ok(notes::count(&connection, false)?)
    }

    /// 未删除笔记本数量。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn notebook_count(&self) -> CoreResult<i64> {
        let connection = self.database.connection()?;
        Ok(notebooks::count(&connection)?)
    }

    /// 待同步操作数量（UI 同步状态用）。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn pending_sync_count(&self) -> CoreResult<i64> {
        let connection = self.database.connection()?;
        Ok(nested_db::repositories::sync_operations::pending_count(
            &connection,
        )?)
    }

    /// 某篇笔记的修订历史，**按版本倒序**（最新在前）。
    ///
    /// `limit = 0` 时用默认值 50。
    ///
    /// ## 为什么 Core 要暴露它
    ///
    /// 修订历史是铁律 T6（每次修改可追踪）的对外体现：用户应当能回答
    /// "这篇笔记改过几次、什么时候改的"。P3 的"版本历史"面板会直接消费它。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn revision_history(
        &self,
        note_id: &Id,
        limit: u32,
    ) -> CoreResult<Vec<nested_model::Revision>> {
        let connection = self.database.connection()?;
        let effective = if limit == 0 { 50 } else { limit };
        Ok(revisions::list_for_note(&connection, note_id, effective)?)
    }

    // ---------------------------------------------------------------- 附件

    /// 附件存储根目录（内存库模式下为 `None`）。
    #[must_use]
    pub fn attachments_dir(&self) -> Option<PathBuf> {
        self.attachments
            .as_ref()
            .map(|service| service.root().to_path_buf())
    }

    /// 附件服务（未启用时报错并说明原因）。
    fn attachment_service(&self) -> CoreResult<&crate::attachments::AttachmentService> {
        self.attachments.as_ref().ok_or_else(|| {
            CoreError::Config("当前内核以内存库模式运行，没有数据目录，无法存储附件".to_owned())
        })
    }

    /// 存储一段字节为附件，并把它**挂到某篇笔记上**（一次完成）。
    ///
    /// ## 为什么"存储"与"挂到笔记"是同一个操作
    ///
    /// 附件若只写进库、却没有出现在任何笔记的内容里，它就是不可见的孤儿：
    /// 用户看不到它，同步也带不上它。因此对外只暴露这一个方法——
    /// **一次性完成"落盘 + 登记 + 关联 + 保存笔记"**，不提供"只存不挂"的路径。
    ///
    /// ## 顺序（见 `crate::attachments` 模块文档）
    ///
    /// 1. 写文件（原子：临时文件 → fsync → rename → 回读校验）；
    /// 2. 一个事务内完成：附件元数据 upsert + 笔记内容更新 + 附件关联 + 修订 + 入队。
    ///
    /// 若第 2 步失败，文件残留为**孤儿**——安全（可被 GC 回收），
    /// 而不是"有记录没文件"的断链。
    ///
    /// ## 文档中的表示
    ///
    /// 附件会在文档末尾追加一个 `Block::Attachment`，其 `attachment_id` 指向刚登记的附件。
    /// 这是"文档引用附件"的唯一方式——关系表 `note_attachments` 由
    /// `sync_note_links` 从文档推导，不手工维护。
    ///
    /// # Errors
    ///
    /// - 内核运行在内存库模式 → [`CoreError::Config`]
    /// - 标题/摘要非法 → [`CoreError::Validation`]
    /// - 笔记不存在 → [`CoreError::NotFound`]
    /// - 文件或数据库写入失败 → [`CoreError::Config`] / [`CoreError::Database`]
    pub fn attach_bytes_to_note(
        &self,
        note_id: &Id,
        bytes: &[u8],
        mime_type: &str,
        filename: &str,
        device_id: &str,
        at_ms: i64,
    ) -> CoreResult<Attachment> {
        let service = self.attachment_service()?;
        let attachment = service.store_bytes(self, bytes, mime_type, filename, at_ms)?;
        self.link_attachment(note_id, &attachment, device_id, at_ms)?;
        Ok(attachment)
    }

    /// 从文件存储附件并挂到笔记上（流式，大文件不整读进内存）。
    ///
    /// 语义与 [`NestedCore::attach_bytes_to_note`] 相同，只是数据来源是文件。
    ///
    /// # Errors
    ///
    /// 同 [`NestedCore::attach_bytes_to_note`]；源文件不可读时返回 [`CoreError::Config`]。
    pub fn attach_file_to_note(
        &self,
        note_id: &Id,
        source: &Path,
        mime_type: &str,
        filename: &str,
        device_id: &str,
        at_ms: i64,
    ) -> CoreResult<Attachment> {
        let service = self.attachment_service()?;
        let attachment = service.store_file(self, source, mime_type, filename, at_ms)?;
        self.link_attachment(note_id, &attachment, device_id, at_ms)?;
        Ok(attachment)
    }

    /// 把已登记的附件挂到笔记上（把 id 写进文档并保存）。
    fn link_attachment(
        &self,
        note_id: &Id,
        attachment: &Attachment,
        device_id: &str,
        at_ms: i64,
    ) -> CoreResult<()> {
        let note = self.get_note(note_id)?;
        let mut document = self.get_note_document(note_id)?;

        // 幂等：同一附件重复挂到同一笔记时不再追加块
        // （这也让"重复粘贴同一张图"不会产生多个块）
        if !document.attachment_ids().contains(&attachment.id) {
            document.blocks.push(block_for_attachment(attachment));
        }

        // 只改文档，元数据保持库中的值；save_note 只在确有变化时写盘
        // （因此"重复挂同一附件"不会产生多余修订——技术债 #11 的语义在此生效）
        self.save_note(note, document, device_id, at_ms)?;
        Ok(())
    }

    /// 读取附件内容（**读取时校验哈希**，铁律 D4）。
    ///
    /// # Errors
    ///
    /// - 内存库模式 → [`CoreError::Config`]
    /// - 内容缺失（断链） → [`CoreError::NotFound`]
    /// - 内容与哈希不符 → [`CoreError::Config`]
    pub fn read_attachment(&self, sha256: &str) -> CoreResult<Vec<u8>> {
        self.attachment_service()?.read(sha256)
    }

    /// 按标识读取附件元数据。
    ///
    /// # Errors
    ///
    /// 不存在 → [`CoreError::NotFound`]。
    pub fn get_attachment(&self, id: &Id) -> CoreResult<Attachment> {
        let connection = self.database.connection()?;
        nested_db::repositories::attachments::get(&connection, id)?.ok_or(CoreError::NotFound {
            entity: "attachment",
        })
    }

    /// 列出某篇笔记引用的附件。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_attachments_for_note(&self, note_id: &Id) -> CoreResult<Vec<Attachment>> {
        let connection = self.database.connection()?;
        Ok(nested_db::repositories::attachments::list_for_note(
            &connection,
            note_id,
        )?)
    }

    /// 校验某附件的文件与哈希是否一致（备份前体检用）。
    ///
    /// # Errors
    ///
    /// 缺失 → [`CoreError::NotFound`]；不符 → [`CoreError::Config`]。
    pub fn verify_attachment(&self, sha256: &str) -> CoreResult<()> {
        self.attachment_service()?.verify(sha256)
    }

    /// 回收孤儿附件文件（语义见 [`crate::attachments::AttachmentService::gc`]）。
    ///
    /// # Errors
    ///
    /// 内存库模式 → [`CoreError::Config`]；遍历或查询失败 → 相应错误。
    pub fn gc_attachments(&self, now_ms: i64) -> CoreResult<crate::attachments::GcReport> {
        self.attachment_service()?.gc(self, now_ms)
    }
}

/// 为附件选择文档中的块类型。
///
/// 块模型里没有"通用附件块"：图片用 [`Block::Image`]（可带替代文本与尺寸），
/// 其余一律用 [`Block::File`]（带展示用文件名）。
///
/// 依据是 **MIME 类型**而不是文件扩展名——扩展名是用户可控的字符串，
/// 而 MIME 由导入路径根据真实内容判断（铁律 S6：不信任文件名）。
fn block_for_attachment(attachment: &Attachment) -> Block {
    if attachment.mime_type.starts_with("image/") {
        Block::Image {
            attachment_id: attachment.id,
            alt: None,
            width: None,
            height: None,
        }
    } else {
        Block::File {
            attachment_id: attachment.id,
            filename: attachment.filename.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nested_model::Block;

    const NOW: i64 = 1_700_000_000_000;

    #[test]
    fn open_in_memory_is_ready() {
        let core = NestedCore::open_in_memory().expect("open");
        let checks = core.readiness();
        for (name, ok) in checks {
            assert!(ok, "就绪检查失败：{name}");
        }
        assert_eq!(
            core.schema_version().expect("version"),
            nested_db::migrations::LATEST_VERSION
        );
    }

    #[test]
    fn open_creates_database_file_in_data_dir() {
        let dir = tempfile::tempdir().expect("tempdir");
        let core = NestedCore::open(dir.path()).expect("open");
        let path = core.database_path().expect("file backed");
        assert!(path.exists(), "应创建数据库文件：{}", path.display());
        assert!(path.ends_with(crate::branding::DATABASE_FILE));
    }

    #[test]
    fn note_lifecycle_end_to_end() {
        let core = NestedCore::open_in_memory().expect("open");
        let notebook = core.create_notebook("工作", None, NOW).expect("notebook");
        let note = core
            .create_note_with_document(
                Some(notebook.id),
                "第一篇",
                Document::from_blocks(vec![Block::paragraph("你好，世界")], NOW),
                "device-a",
                NOW,
            )
            .expect("note");

        assert_eq!(core.note_count().expect("count"), 1);
        assert_eq!(core.notebook_count().expect("count"), 1);

        let loaded = core.get_note(&note.id).expect("get");
        assert_eq!(loaded.title, "第一篇");
        assert_eq!(
            core.get_note_document(&note.id).expect("doc").blocks.len(),
            1
        );

        // 保存：版本递增
        let mut document = core.get_note_document(&note.id).expect("doc");
        document.blocks.push(Block::paragraph("第二段"));
        let saved = core
            .save_note(loaded, document, "device-a", NOW + 1000)
            .expect("save");
        assert_eq!(saved.version, 2);

        // 删除与恢复
        core.delete_note(&note.id, NOW + 2000).expect("delete");
        assert_eq!(core.note_count().expect("count"), 0);
        let all = core
            .list_notes(&NoteQuery {
                include_deleted: true,
                ..NoteQuery::default()
            })
            .expect("list");
        assert_eq!(all.len(), 1);
        core.restore_note(&note.id, NOW + 3000).expect("restore");
        assert_eq!(core.note_count().expect("count"), 1);
    }

    #[test]
    fn missing_note_is_not_found() {
        let core = NestedCore::open_in_memory().expect("open");
        let error = core.get_note(&Id::new()).expect_err("must fail");
        assert_eq!(error.code(), "NOT_FOUND");
    }

    #[test]
    fn duplicate_tag_is_conflict() {
        let core = NestedCore::open_in_memory().expect("open");
        core.create_tag("灵感", NOW).expect("first");
        let error = core.create_tag("灵感", NOW).expect_err("duplicate");
        assert_eq!(error.code(), "CONFLICT");
        assert!(error.user_hint().contains("冲突"));
    }

    #[test]
    fn invalid_title_is_validation_error() {
        let core = NestedCore::open_in_memory().expect("open");
        let long = "汉".repeat(nested_model::MAX_TITLE_CHARS + 1);
        let error = core.create_note(None, long, NOW).expect_err("too long");
        assert_eq!(error.code(), "VALIDATION_ERROR");
    }

    #[test]
    fn save_with_changed_content_increments_version_and_enqueues() {
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "同步", NOW).expect("create");
        assert_eq!(note.version, 1);

        // 真正改了内容
        let mut document = core.get_note_document(&note.id).expect("doc");
        document.blocks = vec![nested_model::Block::paragraph("改过的内容")];
        let saved = core
            .save_note(note, document, "device-a", NOW + 1)
            .expect("save");

        assert_eq!(saved.version, 2, "有变更时必须递增版本（铁律 T6）");
        // 创建 1 条 + 更新 1 条（铁律 T3 / 技术债 #12）
        assert_eq!(
            core.pending_sync_count().expect("pending"),
            2,
            "创建与更新都应入队"
        );
    }

    #[test]
    fn saving_unchanged_content_does_nothing() {
        // 回归测试（技术债 #11）：修正前 `save_note` 无条件 `touch()`，
        // 于是"一个字都没改"的保存也会推进版本、写一条修订并入队。
        // 这不只是历史记录被污染的问题——它让**自动保存无法实现**：
        // 每次按键都会产生一条修订与一次同步操作。
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "无变更", NOW).expect("create");
        let document = core.get_note_document(&note.id).expect("doc");

        let pending_before = core.pending_sync_count().expect("pending");
        let saved = core
            .save_note(note, document, "device-a", NOW + 5000)
            .expect("save");

        assert_eq!(saved.version, 1, "内容未变时不得递增版本");
        assert_eq!(
            core.pending_sync_count().expect("pending"),
            pending_before,
            "内容未变时不得产生同步操作"
        );
        let revisions = core.revision_history(&saved.id, 10).expect("history");
        assert_eq!(revisions.len(), 1, "内容未变时不得追加修订记录");
    }

    #[test]
    fn saving_unchanged_content_does_not_move_updated_at() {
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "时间戳", NOW).expect("create");
        let document = core.get_note_document(&note.id).expect("doc");
        let before = note.updated_at_ms;

        let saved = core
            .save_note(note, document, "device-a", NOW + 9999)
            .expect("save");
        assert_eq!(
            saved.updated_at_ms, before,
            "无变更保存不应改变修改时间（否则列表排序会被无意义地打乱）"
        );
    }

    #[test]
    fn changing_only_the_title_still_counts_as_a_change() {
        // 只改标题、内容不动，也必须产生修订与入队——
        // 否则"改了标题"这件事永远同步不出去。
        let core = NestedCore::open_in_memory().expect("open");
        let mut note = core.create_note(None, "原标题", NOW).expect("create");
        let document = core.get_note_document(&note.id).expect("doc");

        note.set_title("新标题".to_owned()).expect("valid title");
        let saved = core
            .save_note(note, document, "device-a", NOW + 1)
            .expect("save");

        assert_eq!(saved.title, "新标题");
        assert_eq!(saved.version, 2, "标题变更也应递增版本");
        assert_eq!(core.pending_sync_count().expect("pending"), 2);
    }

    #[test]
    fn revisions_form_a_parent_chain() {
        // 技术债 #11 的另一半：此前 `parent_revision_id` 恒为 None，
        // 修订之间互不相干，P6 的并发分叉检测缺少依据。
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "链", NOW).expect("create");

        // 两次内容不同的保存
        for (index, text) in ["第一次", "第二次"].iter().enumerate() {
            let current = core.get_note(&note.id).expect("get");
            let mut document = core.get_note_document(&note.id).expect("doc");
            document.blocks = vec![nested_model::Block::paragraph(*text)];
            // 用 u32 中转而不是直接 `as i64`：后者在 64 位平台上可能回绕，
            // clippy 的 cast_possible_wrap 正是在拦这个（铁律 R 组要求零警告）。
            let offset = i64::from(u32::try_from(index).expect("索引很小"));
            core.save_note(current, document, "device-a", NOW + 10 * (offset + 1))
                .expect("save");
        }

        let history = core.revision_history(&note.id, 10).expect("history");
        assert_eq!(history.len(), 3, "创建 + 两次保存 = 3 条修订");

        // history 按版本倒序：v3 的父应是 v2，v2 的父应是 v1，v1 无父
        assert_eq!(history[0].version, 3);
        assert_eq!(history[1].version, 2);
        assert_eq!(history[2].version, 1);

        assert_eq!(
            history[0].parent_revision_id,
            Some(history[1].id),
            "v3 的父指针应指向 v2"
        );
        assert_eq!(
            history[1].parent_revision_id,
            Some(history[2].id),
            "v2 的父指针应指向 v1"
        );
        assert_eq!(history[2].parent_revision_id, None, "首条修订没有父");
    }

    #[test]
    fn creating_a_notebook_enqueues_a_sync_operation() {
        // 回归测试（技术债 #12 的连带发现）：笔记本变更此前完全不入队，
        // 且 0001 的 `sync_operations.note_id` 外键会直接拒绝笔记本 id
        // （787 FOREIGN KEY constraint failed）。迁移 0002 修掉了外键，
        // 本测试锁住"笔记本创建也会入队"。
        let core = NestedCore::open_in_memory().expect("open");
        core.create_notebook("工作", None, NOW).expect("notebook");
        assert_eq!(core.pending_sync_count().expect("pending"), 1);
    }

    #[test]
    fn deleting_and_restoring_a_note_enqueue_sync_operations() {
        // 墓碑必须同步（铁律 D9）：否则别的设备会把已删除的笔记"复活"。
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "墓碑", NOW).expect("create");
        assert_eq!(core.pending_sync_count().expect("pending"), 1, "创建入队");

        core.delete_note(&note.id, NOW + 1).expect("delete");
        assert_eq!(core.pending_sync_count().expect("pending"), 2, "删除入队");

        core.restore_note(&note.id, NOW + 2).expect("restore");
        assert_eq!(core.pending_sync_count().expect("pending"), 3, "恢复入队");
    }

    #[test]
    fn device_id_falls_back_to_unknown_and_is_cached() {
        let core = NestedCore::open_in_memory().expect("open");
        // 未注册设备时用兜底值，且不擅自写库
        assert_eq!(core.device_id().expect("device"), UNKNOWN_DEVICE_ID);
        assert!(
            core.database()
                .setting(DEVICE_ID_SETTING_KEY)
                .expect("setting")
                .is_none(),
            "内核不应擅自生成并持久化设备标识"
        );
        // 第二次调用走缓存，仍返回同一值
        assert_eq!(core.device_id().expect("device"), UNKNOWN_DEVICE_ID);
    }

    #[test]
    fn device_id_is_read_from_settings_when_present() {
        let core = NestedCore::open_in_memory().expect("open");
        core.database()
            .set_setting(DEVICE_ID_SETTING_KEY, "device-from-settings", NOW)
            .expect("set");
        assert_eq!(core.device_id().expect("device"), "device-from-settings");
    }

    #[test]
    fn notebooks_and_tags_are_listed() {
        let core = NestedCore::open_in_memory().expect("open");
        core.create_notebook("工作", None, NOW).expect("nb");
        core.create_tag("重要", NOW).expect("tag");
        assert_eq!(core.list_notebooks().expect("list").len(), 1);
        assert_eq!(core.list_tags().expect("list").len(), 1);
    }

    // ---------------------------------------------------------------- 笔记本树

    // ------------------------------------------------------------ 修订对比

    /// 造一篇笔记并保存若干个版本，返回 (笔记 id, 各版本的修订 id)。
    ///
    /// 每次返回的修订 id 按版本**升序**，便于 `diff_revisions(&ids[0], &ids[1])` 这样写。
    /// 造一篇笔记并依次保存若干版本，返回 (笔记 id, 各版本的修订 id)。
    ///
    /// 每个版本是**一组段落**（而不是一个字符串）——这是本辅助函数第一版的
    /// 错误：它只把每版的第一个字符串当成一个段落，于是"两版共有的那一行"
    /// 根本没进快照，diff 自然把它算成新增。
    /// 段落数不同时 diff 的 added/removed 计数本来就会变，
    /// 因此测试要按"哪些行出现"断言，而不是数行数。
    ///
    /// 返回的修订 id 按版本**升序**。
    fn note_with_versions(core: &NestedCore, versions: &[&[&str]]) -> (Id, Vec<Id>) {
        let device = core.device_id().expect("device");
        let paragraphs = |texts: &[&str], at: i64| {
            nested_model::Document::from_blocks(
                texts.iter().map(|t| Block::paragraph(*t)).collect(),
                at,
            )
        };

        let first = versions[0];
        let mut note = core
            .create_note_with_document(None, first[0], paragraphs(first, NOW), &device, NOW)
            .expect("create");

        let mut ids = Vec::new();
        for (index, texts) in versions.iter().enumerate() {
            let at = NOW + i64::try_from(index).expect("small") * 1000;
            if index > 0 {
                note.touch(at);
                note = core
                    .save_note(note.clone(), paragraphs(texts, at), &device, at)
                    .expect("save");
            }
            ids.push(core.revision_history(&note.id, 100).expect("history")[0].id);
        }
        // history 是版本倒序，翻正
        ids.reverse();
        (note.id, ids)
    }

    #[test]
    fn every_write_produces_a_revision_with_a_snapshot() {
        let core = NestedCore::open_in_memory().expect("open");
        let (note_id, ids) = note_with_versions(&core, &[&["第一版"], &["第二版"], &["第三版"]]);

        assert_eq!(ids.len(), 3, "三次写入应留下三条修订");
        assert_eq!(
            core.revision_snapshot_count(&note_id).expect("count"),
            3,
            "每条修订都必须有内容快照，否则对比功能对它是空的"
        );
    }

    #[test]
    fn diff_reports_added_and_removed_lines() {
        let core = NestedCore::open_in_memory().expect("open");
        // 注意要传三个版本：第 i 个参数对应第 i+1 版，而下面要比的是
        // "第 2 版 → 第 4 版"。传少了会拿到错误的基线
        // （本测试第一版就是这样，diff 出来 removed=0）。
        let (note_id, ids) =
            note_with_versions(&core, &[&["第一版"], &["旧内容", "共有的"], &["第三版"]]);
        // 第 4 版换成 [新内容, 共有的]
        let fourth = {
            let device = core.device_id().expect("device");
            let document = nested_model::Document::from_blocks(
                vec![Block::paragraph("新内容"), Block::paragraph("共有的")],
                NOW + 5000,
            );
            let mut note = core.get_note(&note_id).expect("note");
            note.touch(NOW + 5000);
            core.save_note(note, document, &device, NOW + 5000)
                .expect("save");
            core.revision_history(&note_id, 100).expect("history")[0].id
        };

        // ids[1] 是第 2 版（内容 = "旧内容"），fourth 是第 4 版
        let diff = core.diff_revisions(&ids[1], &fourth).expect("diff");
        match diff {
            RevisionDiff::Diff {
                added,
                removed,
                lines,
                ..
            } => {
                // 按**语义**断言"哪些行出现了"，而不是数行数。
                // 数行数会把"两版段落数不同"这类无关细节变成断言的一部分，
                // 从而测出错误的失败（本测试第一版与第二版都栽在这里）。
                assert!(
                    lines
                        .iter()
                        .any(|l| l.kind == DiffLineKind::Removed && l.text == "旧内容"),
                    "「旧内容」必须作为删除行出现，实际：{lines:?}"
                );
                assert!(
                    lines
                        .iter()
                        .any(|l| l.kind == DiffLineKind::Added && l.text == "新内容"),
                    "「新内容」必须作为新增行出现，实际：{lines:?}"
                );
                assert!(
                    lines
                        .iter()
                        .any(|l| l.kind == DiffLineKind::Unchanged && l.text == "共有的"),
                    "未改动的行必须保持 Unchanged，否则对比没有信息量。\
                     实际差异：{}",
                    lines
                        .iter()
                        .map(|l| format!("{:?}:{}", l.kind, l.text))
                        .collect::<Vec<_>>()
                        .join(" | ")
                );
                assert!(added >= 1 && removed >= 1, "两版确实有差异");
            }
            other @ RevisionDiff::MissingSnapshot { .. } => {
                panic!("期望拿到差异，实际：{other:?}")
            }
        }
    }

    #[test]
    fn diff_of_a_revision_with_itself_is_empty() {
        let core = NestedCore::open_in_memory().expect("open");
        let (_note_id, ids) = note_with_versions(&core, &[&["内容"]]);
        let diff = core.diff_revisions(&ids[0], &ids[0]).expect("diff");
        match diff {
            RevisionDiff::Diff {
                added,
                removed,
                lines,
                ..
            } => {
                assert_eq!((added, removed), (0, 0));
                assert!(lines.iter().all(|l| l.kind == DiffLineKind::Unchanged));
            }
            other @ RevisionDiff::MissingSnapshot { .. } => {
                panic!("同一版本对比应当是空差异，实际：{other:?}")
            }
        }
    }

    #[test]
    fn legacy_revision_without_snapshot_is_reported_as_missing_not_empty() {
        // 迁移 0003 之前的历史修订没有快照。
        // 这是本功能最容易出错的地方：把"没有快照"说成"没有差异"，
        // 用户会以为两版内容相同，而事实是我们不知道。
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "老笔记", NOW).expect("create");

        // ⚠ 必须先取"当前最新修订"，**再**插入 legacy。
        // legacy 的 version 是 99，一旦插进去它自己就成最新的了，
        // 再调 revision_history(...)[0] 拿到的会是 legacy 本身——
        // 于是变成"legacy 和自己比"，两边都缺快照，断言随之失败。
        // 本测试前两版都栽在这个顺序上，所以把取 id 放在最前面。
        let current = core.revision_history(&note.id, 100).expect("history")[0].id;

        // 手工造一条"没有快照"的修订，模拟迁移前的数据
        let legacy =
            nested_model::Revision::new(note.id, 99, None, "old-device", "note.update", NOW + 1);
        {
            let connection = core.database.connection().expect("conn");
            nested_db::repositories::revisions::insert(&connection, &legacy).expect("insert");
        }

        assert_eq!(
            core.revision_snapshot(&legacy.id).expect("snapshot"),
            None,
            "没有快照必须返回 None，不能退化成空文档"
        );
        assert!(
            core.revision_snapshot(&current)
                .expect("snapshot")
                .is_some(),
            "前置条件：当前修订必须有快照"
        );

        let diff = core.diff_revisions(&current, &legacy.id).expect("diff");
        match diff {
            RevisionDiff::MissingSnapshot {
                old_missing,
                new_missing,
                ..
            } => {
                assert!(new_missing, "legacy 修订缺快照");
                assert!(!old_missing, "当前修订应当有快照");
            }
            RevisionDiff::Diff { added, removed, .. } => panic!(
                "缺快照绝不能被当成差异（added={added} removed={removed}）——\
                 那会让用户以为两版内容一样"
            ),
        }
    }

    #[test]
    fn snapshot_of_missing_revision_is_not_found() {
        let core = NestedCore::open_in_memory().expect("open");
        assert!(matches!(
            core.revision_snapshot(&Id::new()),
            Err(CoreError::NotFound { .. })
        ));
    }

    /// 建一棵三层笔记本树：根 → 中 → 叶。    /// 建一棵三层笔记本树：根 → 中 → 叶。
    fn notebook_tree(core: &NestedCore) -> (Id, Id, Id) {
        let root = core.create_notebook("根", None, NOW).expect("root");
        let mid = core.create_notebook("中", Some(root.id), NOW).expect("mid");
        let leaf = core.create_notebook("叶", Some(mid.id), NOW).expect("leaf");
        (root.id, mid.id, leaf.id)
    }

    // ------------------------------------------------------------ 移动笔记本

    #[test]
    fn moving_a_notebook_reparents_it() {
        let core = NestedCore::open_in_memory().expect("open");
        let (root, _mid, leaf) = notebook_tree(&core);

        core.move_notebook(&leaf, Some(&root), NOW + 1)
            .expect("把叶节点提到根下");

        let tree = core.list_notebook_tree().expect("tree");
        let shape: Vec<(&str, u32)> = tree
            .iter()
            .map(|(notebook, depth)| (notebook.name.as_str(), *depth))
            .collect();
        assert_eq!(shape, vec![("根", 0), ("中", 1), ("叶", 1)]);
    }

    #[test]
    fn moving_a_notebook_to_top_level_works() {
        let core = NestedCore::open_in_memory().expect("open");
        let (_root, mid, _leaf) = notebook_tree(&core);
        core.move_notebook(&mid, None, NOW + 1).expect("移到顶层");

        // ⚠ 不要按下标断言：`list_notebook_tree` 的**兄弟节点按名称排序**
        // （它取自 list_all 的 ORDER BY name），不是插入顺序。
        // 按名字查深度才是稳定的写法——本测试第一版就是在这里失败的。
        let tree = core.list_notebook_tree().expect("tree");
        let depth_of = |name: &str| -> Option<u32> {
            tree.iter()
                .find(|(notebook, _)| notebook.name == name)
                .map(|(_, depth)| *depth)
        };
        assert_eq!(depth_of("中"), Some(0), "移到顶层后深度应为 0");
        assert_eq!(depth_of("叶"), Some(1), "叶节点应随父节点一起上移");
        assert_eq!(depth_of("根"), Some(0));
    }

    #[test]
    fn moving_a_notebook_into_its_own_descendant_is_refused() {
        // 这条是"不报错但会卡死"的防线：数据库会接受这次 UPDATE，
        // 之后 list_notebook_tree 就会无限递归。
        let core = NestedCore::open_in_memory().expect("open");
        let (root, _mid, leaf) = notebook_tree(&core);

        let error = core
            .move_notebook(&root, Some(&leaf), NOW + 1)
            .expect_err("把根移到叶下必须被拒绝");

        // 关键：错误码必须可区分，不能是泛化的 DATABASE_ERROR——
        // 那会让界面提示"请重启应用"，而实际上是"换个位置就好"。
        assert_eq!(error.code(), "WOULD_CREATE_CYCLE");
        // 而且**不能**被标记为可重试：重试永远不会成功
        assert!(!error.is_retryable(), "成环是确定性失败，不该重试");

        // 树必须保持原样
        let tree = core.list_notebook_tree().expect("tree");
        assert_eq!(tree.len(), 3);
        assert_eq!(tree[0].1, 0);
        assert_eq!(tree[2].1, 2, "被拒绝的移动不应改动层级");
    }

    // -------------------------------------------------------------- 回收站清理

    #[test]
    fn trash_retention_is_15_days() {
        // 保留期是产品决定，写死在测试里是为了"改它时必须有人看见"
        assert_eq!(NestedCore::TRASH_RETENTION_DAYS, 15);
        assert_eq!(NestedCore::trash_retention_ms(), 15 * 24 * 60 * 60 * 1000);
    }

    #[test]
    fn purge_removes_only_notes_past_the_retention_period() {
        let core = NestedCore::open_in_memory().expect("open");
        let cutoff = NOW - NestedCore::trash_retention_ms();

        // 刚删的：必须留着（用户还能恢复）
        let recent = core.create_note(None, "刚删的", NOW).expect("create");
        core.delete_note(&recent.id, NOW).expect("delete");

        // 删了很久的：应该被清理
        let old = core.create_note(None, "很久前删的", NOW).expect("create");
        core.delete_note(&old.id, cutoff - 1).expect("delete");

        // 活着的：任何情况都不能碰
        let alive = core.create_note(None, "活着的", NOW).expect("create");

        let report = core.purge_trash(NOW).expect("purge");
        assert_eq!(report.notes_removed, 1);
        assert!(!report.is_empty());

        assert!(core.get_note(&recent.id).is_ok(), "未到期的必须还在");
        assert!(
            matches!(core.get_note(&old.id), Err(CoreError::NotFound { .. })),
            "过期的应被彻底删除"
        );
        assert!(core.get_note(&alive.id).is_ok(), "活跃笔记不该被碰到");
    }

    #[test]
    fn purge_removes_a_notebook_only_after_its_notes_are_purged() {
        // 依赖链：笔记先走 → 笔记本才不再被引用 → 笔记本才能删。
        // 这条测试同时证明"清理不会产生孤儿笔记"。
        let core = NestedCore::open_in_memory().expect("open");
        let cutoff = NOW - NestedCore::trash_retention_ms();
        let book = core.create_notebook("要清掉的", None, NOW).expect("book");
        let note = core
            .create_note(Some(book.id), "里面的笔记", NOW)
            .expect("note");

        // 同一时刻删掉两者（模拟用户删整个笔记本）
        core.delete_note(&note.id, cutoff - 1).expect("del note");
        core.delete_notebook(&book.id, cutoff - 1)
            .expect("del book");

        let report = core.purge_trash(NOW).expect("purge");
        assert_eq!(report.notes_removed, 1);
        assert_eq!(report.notebooks_removed, 1, "笔记清掉后笔记本才能被清");
    }

    #[test]
    fn purge_keeps_a_deleted_notebook_that_still_has_a_live_note() {
        // 最重要的安全性质：定时清理**绝不能**制造孤儿笔记。
        // 用户删了笔记本但把里面的笔记恢复了 → 笔记本必须留着。
        let core = NestedCore::open_in_memory().expect("open");
        let cutoff = NOW - NestedCore::trash_retention_ms();
        let book = core.create_notebook("有活笔记的", None, NOW).expect("book");
        core.create_note(Some(book.id), "活着的笔记", NOW)
            .expect("note");
        core.delete_notebook(&book.id, cutoff - 1)
            .expect("del book");

        let report = core.purge_trash(NOW).expect("purge");
        assert_eq!(report.notebooks_removed, 0, "还有活笔记引用时必须跳过");

        // ⚠ 不能去 list_notebook_tree 里找它：那个列表**只含未删除的**笔记本，
        // 而这条笔记本在回收站里（deleted_at_ms 非空），本来就不该出现在树里。
        // 正确的验证方式是证明**行还在**——用"能恢复"来证明。
        // 本测试第一版就是误用了树查询而失败的。
        assert!(
            core.restore_notebook(&book.id, NOW + 1).is_ok(),
            "被跳过的笔记本必须仍然存在（能恢复），否则它的笔记就成了孤儿"
        );

        // 恢复后应当重新出现在树里，且活笔记仍在它下面
        let tree = core.list_notebook_tree().expect("tree");
        assert!(
            tree.iter().any(|(n, _)| n.name == "有活笔记的"),
            "恢复后应回到树里"
        );
        let notes = core
            .list_notes(&NoteQuery {
                notebook_id: Some(&book.id),
                include_descendants: true,
                ..NoteQuery::default()
            })
            .expect("notes");
        assert_eq!(notes.len(), 1, "那篇活笔记必须还在这个笔记本下");
    }

    #[test]
    fn purge_walks_deep_notebook_nests_to_a_fixed_point() {
        // 目录可以有任意层深。清理必须循环到不动点，
        // 而不是"扫两遍就以为够了"。
        let core = NestedCore::open_in_memory().expect("open");
        let cutoff = NOW - NestedCore::trash_retention_ms();

        let mut parent: Option<Id> = None;
        let mut ids: Vec<Id> = Vec::new();
        for depth in 0..5 {
            let book = core
                .create_notebook(format!("第{depth}层"), parent, NOW)
                .expect("book");
            parent = Some(book.id);
            ids.push(book.id);
        }
        // 从**最深**的开始删，这样每轮只能解开一层
        for id in ids.iter().rev() {
            core.delete_notebook(id, cutoff - 1).expect("del");
        }

        let report = core.purge_trash(NOW).expect("purge");
        assert_eq!(
            report.notebooks_removed, 5,
            "五层嵌套应当被全部清掉（需要多轮才能解开）"
        );

        let tree = core.list_notebook_tree().expect("tree");
        assert!(tree.is_empty(), "清理后树应当是空的，实际：{tree:?}");
    }

    #[test]
    fn purge_on_empty_trash_is_a_no_op() {
        let core = NestedCore::open_in_memory().expect("open");
        core.create_note(None, "还在", NOW).expect("create");
        let report = core.purge_trash(NOW).expect("purge");
        assert!(report.is_empty(), "没有可清理的东西时不该报告删了东西");
        assert_eq!(core.count_expired_trash(NOW).expect("count"), 0);
    }

    #[test]
    fn count_expired_trash_agrees_with_what_purge_removes() {
        // 界面按这个数字提示"下次启动将清理"。若两处判定不一致，
        // 用户会遇到"提示要清理，结果没清"或反过来的情况。
        let core = NestedCore::open_in_memory().expect("open");
        let cutoff = NOW - NestedCore::trash_retention_ms();
        for (title, at) in [("a", cutoff - 1), ("b", cutoff - 2), ("c", NOW)] {
            let note = core.create_note(None, title, NOW).expect("create");
            core.delete_note(&note.id, at).expect("delete");
        }

        let predicted = core.count_expired_trash(NOW).expect("count");
        assert_eq!(predicted, 2);
        let report = core.purge_trash(NOW).expect("purge");
        assert_eq!(
            i64::try_from(report.notes_removed).expect("fits"),
            predicted,
            "count_expired_trash 的数字必须等于 purge 实际删掉的条数"
        );
    }

    #[test]
    fn notebook_tree_is_depth_first_with_depths() {
        let core = NestedCore::open_in_memory().expect("open");
        notebook_tree(&core);

        let tree = core.list_notebook_tree().expect("tree");
        let shape: Vec<(&str, u32)> = tree
            .iter()
            .map(|(notebook, depth)| (notebook.name.as_str(), *depth))
            .collect();

        assert_eq!(
            shape,
            vec![("根", 0), ("中", 1), ("叶", 2)],
            "应为深度优先且深度正确"
        );
    }

    #[test]
    fn siblings_of_the_same_parent_all_appear() {
        let core = NestedCore::open_in_memory().expect("open");
        let root = core.create_notebook("根", None, NOW).expect("root");
        core.create_notebook("甲", Some(root.id), NOW).expect("a");
        core.create_notebook("乙", Some(root.id), NOW).expect("b");

        let tree = core.list_notebook_tree().expect("tree");
        assert_eq!(tree.len(), 3);
        assert_eq!(tree[0].1, 0, "根在深度 0");
        assert!(
            tree[1..].iter().all(|(_, depth)| *depth == 1),
            "子级都在深度 1"
        );
    }

    #[test]
    fn orphan_notebook_is_treated_as_top_level_not_dropped() {
        // 父节点不存在的笔记本不能从界面上消失。
        //
        // 注意：正常写入路径**造不出**这种数据——`notebooks.parent_id` 有外键，
        // 指向不存在的父节点会直接报 787（本测试最初就那么失败了，
        // 那反而证明约束在生效）。
        //
        // 但仍必须处理，因为它可能来自**本进程之外**：同步场景（P6）下
        // 对端可能先发子节点、后发父节点；或数据库被外部工具改过。
        // 因此这里绕过外键直接注入坏数据，验证界面不会因此丢节点。
        let core = NestedCore::open_in_memory().expect("open");
        let ghost_parent = Id::new();
        let orphan = Notebook::new("孤儿", Some(ghost_parent), NOW).expect("valid");

        {
            let connection = core.database().connection().expect("conn");
            connection
                .execute_batch("PRAGMA foreign_keys = OFF")
                .expect("disable fk for injection");
            nested_db::repositories::notebooks::insert_in_transaction(&connection, &orphan)
                .expect("inject orphan");
            connection
                .execute_batch("PRAGMA foreign_keys = ON")
                .expect("re-enable fk");
        }

        let tree = core.list_notebook_tree().expect("tree");
        assert_eq!(tree.len(), 1, "孤儿节点必须仍然出现");
        assert_eq!(tree[0].0.id, orphan.id);
        assert_eq!(tree[0].1, 0, "孤儿被当作顶层");
    }

    #[test]
    fn subtree_ids_include_self_and_all_descendants() {
        let core = NestedCore::open_in_memory().expect("open");
        let (root, mid, leaf) = notebook_tree(&core);

        let from_root = core.notebook_subtree_ids(&root).expect("subtree");
        assert_eq!(from_root.len(), 3, "根 + 中 + 叶");
        assert!(from_root.contains(&root));
        assert!(from_root.contains(&mid));
        assert!(from_root.contains(&leaf));

        let from_mid = core.notebook_subtree_ids(&mid).expect("subtree");
        assert_eq!(from_mid.len(), 2, "中 + 叶，不含根");
        assert!(!from_mid.contains(&root));

        let from_leaf = core.notebook_subtree_ids(&leaf).expect("subtree");
        assert_eq!(from_leaf, vec![leaf], "叶子只有自己");
    }

    #[test]
    fn subtree_ids_for_missing_notebook_is_not_found() {
        let core = NestedCore::open_in_memory().expect("open");
        let error = core
            .notebook_subtree_ids(&Id::new())
            .expect_err("必须报 NotFound");
        assert_eq!(error.code(), "NOT_FOUND");
    }

    #[test]
    fn selecting_a_parent_notebook_lists_descendant_notes() {
        // 端到端：建树 + 各层放笔记 → 按父级列表应看到全部子孙笔记
        let core = NestedCore::open_in_memory().expect("open");
        let (root, mid, leaf) = notebook_tree(&core);
        for (notebook, title) in [(root, "根笔记"), (mid, "中笔记"), (leaf, "叶笔记")] {
            core.create_note(Some(notebook), title, NOW).expect("note");
        }

        let query = NoteQuery {
            notebook_id: Some(&root),
            include_descendants: true,
            ..NoteQuery::default()
        };
        let notes = core.list_notes(&query).expect("list");
        assert_eq!(notes.len(), 3, "父级列表应包含三层笔记");

        // 默认（不含子孙）只看本层
        let direct = NoteQuery {
            notebook_id: Some(&root),
            ..NoteQuery::default()
        };
        assert_eq!(core.list_notes(&direct).expect("list").len(), 1);
    }

    #[test]
    fn notebook_hierarchy_survives_reopen() {
        let dir = tempfile::tempdir().expect("tempdir");
        let leaf_name = {
            let core = NestedCore::open(dir.path()).expect("open");
            let (_root, _mid, leaf) = notebook_tree(&core);
            core.get_notebook(&leaf).expect("leaf").name
        };
        let core = NestedCore::open(dir.path()).expect("reopen");
        let tree = core.list_notebook_tree().expect("tree");
        assert_eq!(tree.len(), 3, "重启后层级结构必须保留");
        assert_eq!(tree[2].0.name, leaf_name);
        assert_eq!(tree[2].1, 2, "深度也要正确");
    }

    #[test]
    fn creating_a_child_notebook_enqueues_sync_operation() {
        let core = NestedCore::open_in_memory().expect("open");
        let before = core.pending_sync_count().expect("count");
        let root = core.create_notebook("根", None, NOW).expect("root");
        core.create_notebook("子", Some(root.id), NOW)
            .expect("child");
        assert_eq!(
            core.pending_sync_count().expect("count") - before,
            2,
            "每个笔记本创建都应入队"
        );
    }

    #[test]
    fn closing_and_reopening_keeps_data() {
        let dir = tempfile::tempdir().expect("tempdir");
        let note_id = {
            let core = NestedCore::open(dir.path()).expect("open");
            let note = core.create_note(None, "持久化", NOW).expect("create");
            note.id
        };
        let core = NestedCore::open(dir.path()).expect("reopen");
        assert_eq!(core.get_note(&note_id).expect("get").title, "持久化");
    }

    // ---------------------------------------------------------------- 附件
    //
    // 这一组的核心是**不变量**：每一条 attachments 记录，其内容一定已完整落盘。
    // 换句话说"有记录没文件"（断链）绝不允许出现；反过来"有文件没记录"
    // （孤儿）是允许的，因为写入顺序保证了它可被 GC 回收。

    /// 建一个有数据目录的内核 + 一篇笔记。
    fn core_with_note() -> (tempfile::TempDir, NestedCore, Id) {
        let dir = tempfile::tempdir().expect("tempdir");
        let core = NestedCore::open(dir.path()).expect("open");
        let note = core.create_note(None, "带附件", NOW).expect("create");
        (dir, core, note.id)
    }

    #[test]
    fn attaching_bytes_writes_file_and_metadata_and_link() {
        let (_dir, core, note_id) = core_with_note();
        let content = b"binary payload";

        let attachment = core
            .attach_bytes_to_note(
                &note_id,
                content,
                "application/pdf",
                "报告.pdf",
                "device-a",
                NOW + 1,
            )
            .expect("attach");

        // 内容可原样读回（读取时校验哈希）
        assert_eq!(
            core.read_attachment(&attachment.sha256).expect("read"),
            content
        );
        assert_eq!(attachment.size_bytes, content.len() as u64);
        assert_eq!(attachment.filename, "报告.pdf");

        // 元数据已登记
        let stored = core.get_attachment(&attachment.id).expect("get");
        assert_eq!(stored.sha256, attachment.sha256);

        // 笔记里出现了引用
        let document = core.get_note_document(&note_id).expect("doc");
        assert!(
            document.attachment_ids().contains(&attachment.id),
            "文档必须引用该附件"
        );

        // 关系表也已同步（关系由文档推导，不手工维护）
        let linked = core.list_attachments_for_note(&note_id).expect("list");
        assert_eq!(linked.len(), 1);
        assert_eq!(linked[0].id, attachment.id);
    }

    #[test]
    fn image_mime_creates_image_block_and_other_mime_creates_file_block() {
        let (_dir, core, note_id) = core_with_note();

        core.attach_bytes_to_note(&note_id, b"png-bytes", "image/png", "图.png", "d", NOW + 1)
            .expect("attach image");
        core.attach_bytes_to_note(
            &note_id,
            b"zip-bytes",
            "application/zip",
            "归档.zip",
            "d",
            NOW + 2,
        )
        .expect("attach file");

        let blocks = core.get_note_document(&note_id).expect("doc").blocks;
        assert!(
            blocks
                .iter()
                .any(|block| matches!(block, Block::Image { .. })),
            "image/* 应产生图片块"
        );
        assert!(
            blocks
                .iter()
                .any(|block| matches!(block, Block::File { .. })),
            "其它 MIME 应产生文件块"
        );
    }

    #[test]
    fn same_content_is_deduplicated_across_notes() {
        // 内容寻址的核心收益：同一份内容在多篇笔记里只占一份磁盘
        let (_dir, core, first_note) = core_with_note();
        let second_note = core.create_note(None, "第二篇", NOW).expect("create").id;
        let content = b"identical bytes";

        let a = core
            .attach_bytes_to_note(&first_note, content, "text/plain", "a.txt", "d", NOW + 1)
            .expect("a");
        let b = core
            .attach_bytes_to_note(&second_note, content, "text/plain", "b.txt", "d", NOW + 2)
            .expect("b");

        assert_eq!(a.sha256, b.sha256, "相同内容必须有相同哈希");
        assert_eq!(a.id, b.id, "元数据也应复用同一条记录（SHA-256 唯一索引）");

        // 两篇笔记各自引用它，因此删除其中一篇不会让内容消失
        let (_, core2, _) = core_with_note(); // 独立内核，避免相互影响
        drop(core2);
        assert_eq!(
            core.list_attachments_for_note(&first_note)
                .expect("l1")
                .len(),
            1
        );
        assert_eq!(
            core.list_attachments_for_note(&second_note)
                .expect("l2")
                .len(),
            1
        );
    }

    #[test]
    fn attaching_the_same_content_twice_to_one_note_is_idempotent() {
        // 用户重复粘贴同一张图：不应产生第二个块，也不应产生多余修订
        let (_dir, core, note_id) = core_with_note();
        let content = b"same image";

        core.attach_bytes_to_note(&note_id, content, "image/png", "x.png", "d", NOW + 1)
            .expect("first");
        let version_after_first = core.get_note(&note_id).expect("note").version;

        core.attach_bytes_to_note(&note_id, content, "image/png", "x.png", "d", NOW + 2)
            .expect("second");

        let document = core.get_note_document(&note_id).expect("doc");
        assert_eq!(document.attachment_ids().len(), 1, "同一附件不应被追加两次");
        assert_eq!(
            core.get_note(&note_id).expect("note").version,
            version_after_first,
            "无实际变化时不应递增版本（技术债 #11 的语义）"
        );
    }

    #[test]
    fn every_metadata_row_has_its_file_on_disk() {
        // 这是本模块最重要的不变量：**有记录必有文件**。
        // 它是"写入顺序不可颠倒"（先文件后库）的直接推论。
        let (_dir, core, note_id) = core_with_note();

        for index in 0..5 {
            let content = format!("payload-{index}");
            core.attach_bytes_to_note(
                &note_id,
                content.as_bytes(),
                "text/plain",
                &format!("f{index}.txt"),
                "d",
                NOW + index,
            )
            .expect("attach");
        }

        let attachments = core.list_attachments_for_note(&note_id).expect("list");
        assert_eq!(attachments.len(), 5);
        for attachment in &attachments {
            assert!(
                core.verify_attachment(&attachment.sha256).is_ok(),
                "每条元数据都必须有完整落盘的文件：{}",
                attachment.filename
            );
        }
    }

    #[test]
    fn gc_reports_no_broken_links_after_normal_writes() {
        let (_dir, core, note_id) = core_with_note();
        core.attach_bytes_to_note(&note_id, b"x", "text/plain", "x.txt", "d", NOW + 1)
            .expect("attach");

        let report = core.gc_attachments(NOW + 2).expect("gc");
        assert_eq!(report.broken_links, 0, "正常写入后不应有断链");
        assert_eq!(report.removed_files, 0, "被引用的文件不该被删除");
    }

    #[test]
    fn gc_removes_only_orphans_beyond_grace_period() {
        // ⚠️ 本测试必须用**真实系统时间**，不能用固定的 `NOW` 常量。
        //
        // 踩过的坑（本次真实发生）：第一版用 `NOW + GC_GRACE_PERIOD_MS * 10` 当"很久以后"，
        // 但 `NOW` 是 2023-11-14，而文件 mtime 来自真实的系统时钟。
        // 于是 `now_ms - mtime` 是**负数**，`saturating_sub` 归零 →
        // 所有文件都被判为"刚写入、在宽限期内"，GC 一个都没删。
        // 这与踩坑备忘 §5.7 是同一类错误：**把固定测试时间与真实时间混用**。
        let real_now = i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock after epoch")
                .as_millis(),
        )
        .expect("fits in i64");

        let (_dir, core, note_id) = core_with_note();
        let service_root = core.attachments_dir().expect("has data dir");
        let store = nested_attachment::ContentStore::new(service_root);

        // 造两个孤儿文件（没有任何元数据引用它们）
        let recent = store.put_bytes(b"recent orphan").expect("put recent");
        let old = store.put_bytes(b"old orphan").expect("put old");
        assert!(old.path.exists() && recent.path.exists());

        // 1) 以"现在"为基准：两个都在宽限期内，什么都不该删
        let report1 = core.gc_attachments(real_now).expect("gc1");
        assert_eq!(report1.removed_files, 0, "宽限期内不得删除");
        assert_eq!(report1.kept_recent, 2, "两个孤儿都还在宽限期内");

        // 2) 把基准时间推到宽限期之后：两个都该被回收
        let later = real_now + crate::attachments::GC_GRACE_PERIOD_MS * 2;
        let report2 = core.gc_attachments(later).expect("gc2");
        assert_eq!(report2.removed_files, 2, "越过宽限期的孤儿应被回收");
        assert!(report2.freed_bytes > 0, "应统计释放的字节数");
        assert!(
            !old.path.exists() && !recent.path.exists(),
            "孤儿文件应已被删除"
        );

        // 这篇笔记本身没有附件，因此上面的删除不影响任何被引用的内容
        assert!(
            core.list_attachments_for_note(&note_id)
                .expect("list")
                .is_empty()
        );
    }

    #[test]
    fn gc_never_removes_files_referenced_by_deleted_notes() {
        // 软删除的笔记仍引用附件（可从回收站恢复），因此其文件不能被回收。
        // 这是"回收孤儿"最容易写错的地方：按 ref_count 判断会误删。
        let (_dir, core, note_id) = core_with_note();
        let attachment = core
            .attach_bytes_to_note(&note_id, b"keep me", "text/plain", "k.txt", "d", NOW + 1)
            .expect("attach");

        core.delete_note(&note_id, NOW + 2).expect("delete note");

        let far_future = NOW + crate::attachments::GC_GRACE_PERIOD_MS * 10;
        let report = core.gc_attachments(far_future).expect("gc");
        assert_eq!(
            report.removed_files, 0,
            "已删除笔记引用的附件仍须保留（否则恢复笔记后附件就丢了）"
        );
        assert!(core.read_attachment(&attachment.sha256).is_ok());
    }

    #[test]
    fn in_memory_core_rejects_attachment_operations_with_clear_error() {
        // 内存库没有数据目录，附件无法落盘。此时必须**明确报错**，
        // 而不是悄悄写到一个临时位置（那会让测试与真实行为不一致）。
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "内存", NOW).expect("create");

        let error = core
            .attach_bytes_to_note(&note.id, b"x", "text/plain", "x.txt", "d", NOW + 1)
            .expect_err("必须报错");
        assert_eq!(error.code(), "CONFIG_ERROR");
        assert!(core.attachments_dir().is_none());
    }

    #[test]
    fn attaching_from_file_streams_and_links() {
        let (_dir, core, note_id) = core_with_note();
        let source_dir = tempfile::tempdir().expect("tempdir");
        let source = source_dir.path().join("源文件.bin");
        let content = vec![7_u8; 300_000];
        std::fs::write(&source, &content).expect("write source");

        let attachment = core
            .attach_file_to_note(
                &note_id,
                &source,
                "application/octet-stream",
                "源文件.bin",
                "d",
                NOW + 1,
            )
            .expect("attach file");

        assert_eq!(attachment.size_bytes, content.len() as u64);
        assert_eq!(
            core.read_attachment(&attachment.sha256).expect("read"),
            content
        );
    }

    #[test]
    fn attachment_metadata_is_enqueued_for_sync() {
        // 技术债 #22：附件元数据此前完全不入队，其它设备会缺附件
        let (_dir, core, note_id) = core_with_note();
        let before = core.pending_sync_count().expect("count");

        core.attach_bytes_to_note(&note_id, b"sync me", "text/plain", "s.txt", "d", NOW + 1)
            .expect("attach");

        let after = core.pending_sync_count().expect("count");
        assert!(
            after > before,
            "附件元数据必须入队（before={before} after={after}）"
        );
    }

    #[test]
    fn attachments_survive_reopen() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (note_id, sha256) = {
            let core = NestedCore::open(dir.path()).expect("open");
            let note = core.create_note(None, "持久化附件", NOW).expect("create");
            let attachment = core
                .attach_bytes_to_note(&note.id, b"durable", "text/plain", "d.txt", "d", NOW + 1)
                .expect("attach");
            (note.id, attachment.sha256)
        };

        let core = NestedCore::open(dir.path()).expect("reopen");
        assert_eq!(
            core.read_attachment(&sha256).expect("read"),
            b"durable",
            "重启后附件内容必须仍在（铁律 T1）"
        );
        let document = core.get_note_document(&note_id).expect("doc");
        assert_eq!(document.attachment_ids().len(), 1, "引用关系也必须保留");
    }

    #[test]
    fn missing_attachment_reports_not_found_not_panic() {
        let (_dir, core, _note) = core_with_note();
        // 一个合法但从未存储过的哈希
        let error = core
            .read_attachment(&"a".repeat(64))
            .expect_err("必须报 NotFound");
        assert_eq!(error.code(), "NOT_FOUND");
    }
}
