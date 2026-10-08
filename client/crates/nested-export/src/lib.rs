//! # nested-export —— 导出与备份
//!
//! **状态**：P0 仅建立 crate 边界；实现属于 P1（开发计划 §2.1.5）。
//!
//! ## 铁律约束
//!
//! - **D3**：导出与备份写文件必须"临时文件 → fsync → rename"，禁止写一半留下残缺文件。
//! - **D4/D5**：备份必须在 `manifest.json` 记录每个文件的 SHA-256 与条目计数；
//!   恢复前必须先校验 manifest，**禁止**未校验就覆盖用户数据。
//! - **S10**："彻底删除"必须真的删除数据库记录与附件文件。

#![forbid(unsafe_code)]

mod html;
mod markdown;

/// 导出格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    /// Markdown（便于迁移到其他工具）。
    Markdown,
    /// HTML（自包含，含内联样式）。
    Html,
    /// 纯文本。
    Text,
    /// JSON（完整块模型，长期归档格式）。
    Json,
    /// PDF（P3 视依赖风险决定是否实现）。
    Pdf,
}

impl ExportFormat {
    /// 建议的文件扩展名。
    #[must_use]
    pub const fn extension(self) -> &'static str {
        match self {
            Self::Markdown => "md",
            Self::Html => "html",
            Self::Text => "txt",
            Self::Json => "json",
            Self::Pdf => "pdf",
        }
    }
}

/// 备份清单文件名。
pub const MANIFEST_FILE: &str = "manifest.json";

/// 备份目录结构（技术文档 §23）：
///
/// ```text
/// backup/
/// ├── manifest.json
/// ├── notes/
/// ├── attachments/
/// └── metadata/
/// ```
pub const BACKUP_DIRS: [&str; 3] = ["notes", "attachments", "metadata"];

/// 备份清单中的一个条目。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ManifestEntry {
    /// 相对路径。
    pub path: String,
    /// 内容 SHA-256（小写十六进制）。
    pub sha256: String,
    /// 字节数。
    pub size_bytes: u64,
}

/// 备份清单。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct BackupManifest {
    /// 备份格式版本。
    pub format_version: u32,
    /// 生成时间（UTC 毫秒）。
    pub created_at_ms: i64,
    /// 应用版本。
    pub app_version: String,
    /// schema 版本（恢复时必须兼容）。
    pub schema_version: u32,
    /// 笔记数量。
    pub note_count: u64,
    /// 附件数量。
    pub attachment_count: u64,
    /// 条目清单。
    pub entries: Vec<ManifestEntry>,
}

/// 导出层错误。
#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    /// 文件系统错误。
    #[error("导出文件操作失败：{0}")]
    Io(#[from] std::io::Error),

    /// 存储层错误。
    #[error("导出读取数据失败：{0}")]
    Storage(#[from] nested_db::DbError),

    /// 模型层错误（例如文档损坏）。
    #[error("导出内容无效：{0}")]
    Model(#[from] nested_model::ModelError),

    /// 清单校验失败。
    #[error("备份清单校验失败：{reason}")]
    ManifestInvalid {
        /// 具体原因。
        reason: String,
    },
}

/// 导出结果别名。
pub type ExportResult<T> = std::result::Result<T, ExportError>;

pub use html::{base64_encode, document_to_html, escape_html};
pub use markdown::document_to_markdown;
