//! 领域实体：Notebook / Note / Tag / Attachment / Revision。
//!
//! 这些结构体对应数据库表（技术文档 §8），字段语义由本 crate 定义，
//! 由 `nested-db` 负责持久化。
//!
//! 铁律约束：
//! - 时间一律 UTC 毫秒（D8）
//! - 删除一律软删除字段（T7 / D2）
//! - 变更一律有修订记录（T6）

use serde::{Deserialize, Serialize};

use crate::{Id, ModelError, Result};

/// 笔记标题的最大字符数。
pub const MAX_TITLE_CHARS: usize = 512;

/// 摘要的最大字符数。
pub const MAX_SUMMARY_CHARS: usize = 512;

/// 笔记本名称的最大字符数。
pub const MAX_NOTEBOOK_NAME_CHARS: usize = 256;

/// 标签名称的最大字符数。
pub const MAX_TAG_NAME_CHARS: usize = 128;

/// 展示用文件名的最大字符数。
pub const MAX_FILENAME_CHARS: usize = 255;

/// 笔记本（可嵌套成树）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notebook {
    /// 标识。
    pub id: Id,
    /// 名称。
    pub name: String,
    /// 父笔记本（`None` 表示顶层）。
    pub parent_id: Option<Id>,
    /// 创建时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 最近修改时间（UTC 毫秒）。
    pub updated_at_ms: i64,
    /// 软删除时间；`Some` 表示在回收站中（铁律 T7）。
    pub deleted_at_ms: Option<i64>,
}

impl Notebook {
    /// 创建新笔记本。
    ///
    /// # Errors
    ///
    /// 名称为空或超长时返回 [`ModelError::Validation`]。
    pub fn new(name: impl Into<String>, parent_id: Option<Id>, at_ms: i64) -> Result<Self> {
        let name = name.into();
        validate_text("notebook.name", &name, 1, MAX_NOTEBOOK_NAME_CHARS)?;
        Ok(Self {
            id: Id::new(),
            name,
            parent_id,
            created_at_ms: at_ms,
            updated_at_ms: at_ms,
            deleted_at_ms: None,
        })
    }

    /// 是否已被软删除。
    #[must_use]
    pub const fn is_deleted(&self) -> bool {
        self.deleted_at_ms.is_some()
    }
}

/// 笔记。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Note {
    /// 标识。
    pub id: Id,
    /// 所属笔记本（`None` 表示未归类）。
    pub notebook_id: Option<Id>,
    /// 标题（允许为空字符串：新建笔记时用户尚未输入）。
    pub title: String,
    /// 摘要（可为空，由内核生成或用户设置）。
    pub summary: String,
    /// 创建时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 最近修改时间（UTC 毫秒）。
    pub updated_at_ms: i64,
    /// 最近访问时间（UTC 毫秒）。
    pub accessed_at_ms: Option<i64>,
    /// 是否置顶。
    pub is_pinned: bool,
    /// 是否归档。
    pub is_archived: bool,
    /// 软删除时间（`Some` = 在回收站中）。
    pub deleted_at_ms: Option<i64>,
    /// 修订号，每次内容修改递增（铁律 T6）。
    pub version: i64,
}

impl Note {
    /// 创建新笔记。
    ///
    /// # Errors
    ///
    /// 标题或摘要超长时返回 [`ModelError::Validation`]。
    pub fn new(notebook_id: Option<Id>, title: impl Into<String>, at_ms: i64) -> Result<Self> {
        let title = title.into();
        validate_text("note.title", &title, 0, MAX_TITLE_CHARS)?;
        Ok(Self {
            id: Id::new(),
            notebook_id,
            title,
            summary: String::new(),
            created_at_ms: at_ms,
            updated_at_ms: at_ms,
            accessed_at_ms: None,
            is_pinned: false,
            is_archived: false,
            deleted_at_ms: None,
            version: 1,
        })
    }

    /// 是否已被软删除。
    #[must_use]
    pub const fn is_deleted(&self) -> bool {
        self.deleted_at_ms.is_some()
    }

    /// 设置标题并校验。
    ///
    /// # Errors
    ///
    /// 标题超长时返回 [`ModelError::Validation`]。
    pub fn set_title(&mut self, title: impl Into<String>) -> Result<()> {
        let title = title.into();
        validate_text("note.title", &title, 0, MAX_TITLE_CHARS)?;
        self.title = title;
        Ok(())
    }

    /// 设置摘要并校验。
    ///
    /// # Errors
    ///
    /// 摘要超长时返回 [`ModelError::Validation`]。
    pub fn set_summary(&mut self, summary: impl Into<String>) -> Result<()> {
        let summary = summary.into();
        validate_text("note.summary", &summary, 0, MAX_SUMMARY_CHARS)?;
        self.summary = summary;
        Ok(())
    }

    /// 把笔记移到另一个笔记本（`None` 表示移出笔记本，成为"未分类"）。
    ///
    /// ## 为什么不做"目标笔记本必须存在"的校验
    ///
    /// 领域模型是**纯数据**，不持有数据库句柄，因此无法验证目标是否存在。
    /// 这项校验由数据库的外键（`notes.notebook_id REFERENCES notebooks (id)`）
    /// 与仓储层共同保证——写不进去就会报错，不会产生悬空引用。
    ///
    /// 把它放在模型里而不是直接改公开字段，是为了让"移动笔记本"这件事
    /// 有唯一入口（铁律 T4：业务规则收敛在一处）。
    pub fn set_notebook(&mut self, notebook_id: Option<Id>) -> Result<()> {
        self.notebook_id = notebook_id;
        Ok(())
    }

    /// 标记为已修改：刷新时间并递增修订号。
    pub fn touch(&mut self, at_ms: i64) {
        self.updated_at_ms = at_ms;
        self.version = self.version.saturating_add(1);
    }

    /// 移入回收站（软删除，铁律 T7）。
    pub fn soft_delete(&mut self, at_ms: i64) {
        self.deleted_at_ms = Some(at_ms);
        self.updated_at_ms = at_ms;
    }

    /// 从回收站恢复。
    pub fn restore(&mut self, at_ms: i64) {
        self.deleted_at_ms = None;
        self.updated_at_ms = at_ms;
    }
}

/// 标签。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tag {
    /// 标识。
    pub id: Id,
    /// 名称（全局唯一，忽略大小写）。
    pub name: String,
    /// 创建时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 软删除时间。
    pub deleted_at_ms: Option<i64>,
}

impl Tag {
    /// 创建新标签。
    ///
    /// # Errors
    ///
    /// 名称为空或超长时返回 [`ModelError::Validation`]。
    pub fn new(name: impl Into<String>, at_ms: i64) -> Result<Self> {
        let name = name.into();
        validate_text("tag.name", &name, 1, MAX_TAG_NAME_CHARS)?;
        Ok(Self {
            id: Id::new(),
            name,
            created_at_ms: at_ms,
            deleted_at_ms: None,
        })
    }
}

/// 附件元数据。
///
/// **文件本体不进数据库**（铁律 T8）：内容存放在内容寻址存储中，
/// 路径由 [`Attachment::storage_key`] 推导。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    /// 标识。
    pub id: Id,
    /// 内容 SHA-256（十六进制小写，64 字符）。这是去重与完整性校验的依据。
    pub sha256: String,
    /// 真实 MIME 类型（**必须**由内容嗅探得出，禁止只信任扩展名，铁律 S6）。
    pub mime_type: String,
    /// 字节大小。
    pub size_bytes: u64,
    /// 用户可见的原始文件名（仅用于展示，不参与标识）。
    pub filename: String,
    /// 创建时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 墓碑时间：软删除后经过保留期才可被 GC 物理回收（铁律 T7 / D9）。
    pub deleted_at_ms: Option<i64>,
}

impl Attachment {
    /// 创建附件元数据。
    ///
    /// # Errors
    ///
    /// - `sha256` 不是 64 位小写十六进制 → [`ModelError::Validation`]
    /// - 文件名为空或超长 → [`ModelError::Validation`]
    pub fn new(
        sha256: impl Into<String>,
        mime_type: impl Into<String>,
        size_bytes: u64,
        filename: impl Into<String>,
        at_ms: i64,
    ) -> Result<Self> {
        let sha256 = sha256.into();
        if sha256.len() != 64
            || !sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(ModelError::Validation {
                field: "attachment.sha256",
                reason: "必须是 64 位小写十六进制 SHA-256",
            });
        }
        let filename = filename.into();
        validate_text("attachment.filename", &filename, 1, MAX_FILENAME_CHARS)?;
        Ok(Self {
            id: Id::new(),
            sha256,
            mime_type: mime_type.into(),
            size_bytes,
            filename,
            created_at_ms: at_ms,
            deleted_at_ms: None,
        })
    }

    /// 内容寻址存储的相对路径：`<前2位>/<次2位>/<完整哈希>`。
    ///
    /// 与《技术文档》§9 的目录约定一致，两级分片避免单目录文件过多。
    #[must_use]
    pub fn storage_key(&self) -> String {
        format!(
            "{}/{}/{}",
            &self.sha256[0..2],
            &self.sha256[2..4],
            self.sha256
        )
    }
}

/// 修订记录：每一次修改都留下可追踪的痕迹（铁律 T6）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Revision {
    /// 修订标识。
    pub id: Id,
    /// 所属笔记。
    pub note_id: Id,
    /// 修订号（与 [`Note::version`] 对应）。
    pub version: i64,
    /// 父修订（用于同步时判断分叉，`None` 表示首版）。
    pub parent_revision_id: Option<Id>,
    /// 变更发生时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 产生该变更的设备（用于冲突归因）。
    pub device_id: String,
    /// 操作类型描述，如 `"note.update"`。
    pub operation: String,
}

impl Revision {
    /// 创建修订记录。
    #[must_use]
    pub fn new(
        note_id: Id,
        version: i64,
        parent_revision_id: Option<Id>,
        device_id: impl Into<String>,
        operation: impl Into<String>,
        at_ms: i64,
    ) -> Self {
        Self {
            id: Id::new(),
            note_id,
            version,
            parent_revision_id,
            created_at_ms: at_ms,
            device_id: device_id.into(),
            operation: operation.into(),
        }
    }
}

/// 文本字段校验：长度按**字符**计数（不是字节），避免中文被误判超长（铁律 U3）。
///
/// # Errors
///
/// 长度不在 `[min, max]` 区间时返回 [`ModelError::Validation`]。
pub(crate) fn validate_text(
    field: &'static str,
    value: &str,
    min_chars: usize,
    max_chars: usize,
) -> Result<()> {
    let count = value.chars().count();
    if count < min_chars {
        return Err(ModelError::Validation {
            field,
            reason: "长度不足",
        });
    }
    if count > max_chars {
        return Err(ModelError::Validation {
            field,
            reason: "超出最大长度",
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000_000;

    #[test]
    fn note_creation_sets_defaults() {
        let note = Note::new(None, "标题", NOW).expect("valid");
        assert_eq!(note.version, 1);
        assert!(!note.is_deleted());
        assert!(!note.is_pinned);
        assert!(note.notebook_id.is_none());
    }

    #[test]
    fn note_title_length_counts_characters_not_bytes() {
        // 200 个汉字 = 600 字节，但只有 200 字符，必须通过
        let title = "汉".repeat(200);
        assert!(Note::new(None, title, NOW).is_ok());
        // 513 字符必须被拒绝
        assert!(Note::new(None, "汉".repeat(MAX_TITLE_CHARS + 1), NOW).is_err());
    }

    #[test]
    fn note_touch_increments_version_monotonically() {
        let mut note = Note::new(None, "t", NOW).expect("valid");
        note.touch(NOW + 1);
        note.touch(NOW + 2);
        assert_eq!(note.version, 3);
        assert_eq!(note.updated_at_ms, NOW + 2);
    }

    #[test]
    fn soft_delete_then_restore_clears_flag() {
        let mut note = Note::new(None, "t", NOW).expect("valid");
        note.soft_delete(NOW + 10);
        assert!(note.is_deleted());
        note.restore(NOW + 20);
        assert!(!note.is_deleted());
    }

    #[test]
    fn notebook_requires_non_empty_name() {
        assert!(Notebook::new("", None, NOW).is_err());
        assert!(Notebook::new("工作", None, NOW).is_ok());
    }

    #[test]
    fn tag_requires_non_empty_name() {
        assert!(Tag::new("", NOW).is_err());
        assert!(Tag::new("灵感", NOW).is_ok());
    }

    #[test]
    fn attachment_rejects_malformed_hash() {
        assert!(Attachment::new("abc", "image/png", 1, "a.png", NOW).is_err());
        // 大写十六进制也拒绝：存储统一小写，避免同一内容出现两个键
        assert!(Attachment::new("A".repeat(64), "image/png", 1, "a.png", NOW).is_err());
        assert!(Attachment::new("a".repeat(64), "image/png", 1, "a.png", NOW).is_ok());
    }

    #[test]
    fn storage_key_uses_two_level_sharding() {
        let hash = "8f14e45fceea167a5a36dedd4bea2543".to_owned() + &"0".repeat(32);
        let attachment =
            Attachment::new(hash.clone(), "image/png", 10, "p.png", NOW).expect("valid");
        assert_eq!(attachment.storage_key(), format!("8f/14/{hash}"));
    }

    #[test]
    fn revision_keeps_parent_link() {
        let note_id = Id::new();
        let first = Revision::new(note_id, 1, None, "device-a", "note.create", NOW);
        let second = Revision::new(
            note_id,
            2,
            Some(first.id),
            "device-a",
            "note.update",
            NOW + 1,
        );
        assert_eq!(second.parent_revision_id, Some(first.id));
        assert_eq!(second.note_id, note_id);
    }
}
