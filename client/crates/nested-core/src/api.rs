//! 内核对外 API（Domain Service 层）。
//!
//! 这是 Flutter 唯一被允许调用的入口（铁律 A1/A3）：
//! 只暴露**业务语义**操作，不暴露 SQL、表结构、行 ID 之类的实现细节。

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nested_db::NoteQuery;
use nested_db::repositories::{notebooks, notes, tags};
use nested_db::{Database, DbError};
use nested_model::{Document, Id, Note, Notebook, Tag};

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

/// 内核句柄。
#[derive(Debug)]
pub struct NestedCore {
    database: Database,
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
    /// 数据目录内会创建 `nested.db`；附件目录由后续阶段引入。
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
            device_id_cache: Mutex::new(None),
        })
    }

    /// 在内存中打开内核（测试与 CLI 快速验证用）。
    ///
    /// # Errors
    ///
    /// 迁移失败时返回 [`CoreError::Database`]。
    pub fn open_in_memory() -> CoreResult<Self> {
        Ok(Self {
            database: Database::open_in_memory()?,
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

    /// 列出全部未删除笔记本。
    ///
    /// # Errors
    ///
    /// 查询失败 → [`CoreError::Database`]。
    pub fn list_notebooks(&self) -> CoreResult<Vec<Notebook>> {
        let connection = self.database.connection()?;
        Ok(notebooks::list_all(&connection)?)
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

    /// 保存笔记（元数据 + 内容），自动递增修订号并追加修订记录（铁律 T6）。
    ///
    /// # Errors
    ///
    /// - 笔记本标题/摘要非法 → [`CoreError::Validation`]
    /// - 笔记不存在 → [`CoreError::NotFound`]
    pub fn save_note(
        &self,
        mut note: Note,
        document: Document,
        device_id: &str,
        at_ms: i64,
    ) -> CoreResult<Note> {
        note.set_title(note.title.clone())?;
        note.set_summary(note.summary.clone())?;
        note.touch(at_ms);
        let mut connection = self.database.connection()?;
        notes::save_with_document(&mut connection, &note, &document, device_id, None)?;
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
    fn save_increments_version_and_leaves_pending_sync() {
        let core = NestedCore::open_in_memory().expect("open");
        let note = core.create_note(None, "同步", NOW).expect("create");
        let document = core.get_note_document(&note.id).expect("doc");
        core.save_note(note, document, "device-a", NOW + 1)
            .expect("save");

        // **创建也必须入队**（铁律 T3 / 技术债 #12）：
        // 此前只有"更新"入队，导致新建的笔记在 P6 同步时根本不会被推送到其他设备。
        // 因此这里是 2 条：note.create + note.update。
        assert_eq!(
            core.pending_sync_count().expect("pending"),
            2,
            "创建与更新都应入队"
        );
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
}
