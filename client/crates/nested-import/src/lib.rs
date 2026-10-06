//! # nested-import —— 导入（Markdown / HTML / TXT / ENEX → 块模型）
//!
//! **状态**：P0 仅建立 crate 边界；实现属于 P1（开发计划 §2.1.5）。
//!
//! ## 铁律约束
//!
//! - **S5**：外部内容一律视为不可信输入。HTML/ENEX 导入必须清洗脚本、
//!   内联事件与外部跟踪资源，**禁止**产生可执行内容。
//! - **Z3**：必须有真实世界样本的往返（round-trip）测试，覆盖中文、Emoji、
//!   嵌套列表、表格、图片与超长行。
//! - **Z2**：每个格式至少覆盖正常、边界（空文件/超大文件）、失败（编码错误/损坏）三条路径。

#![forbid(unsafe_code)]

use std::path::Path;

use nested_model::Document;

/// 支持的导入格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportFormat {
    /// Markdown（`.md`）。
    Markdown,
    /// HTML（`.html` / `.htm`）。
    Html,
    /// 纯文本（`.txt`）。
    Text,
    /// Evernote 导出（`.enex`）。
    Enex,
}

impl ImportFormat {
    /// 由文件扩展名推断格式（**仅作提示**，真实格式必须嗅探内容，铁律 S6）。
    #[must_use]
    pub fn from_extension(path: &Path) -> Option<Self> {
        match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
            "md" | "markdown" => Some(Self::Markdown),
            "html" | "htm" => Some(Self::Html),
            "txt" => Some(Self::Text),
            "enex" => Some(Self::Enex),
            _ => None,
        }
    }
}

/// 一次导入的产物。
#[derive(Debug, Clone)]
pub struct ImportedNote {
    /// 建议标题（来自文件名、Markdown 首个标题或 ENEX 元数据）。
    pub title: String,
    /// 解析出的文档。
    pub document: Document,
    /// 附带的原始附件（文件名 + 字节 + 嗅探出的 MIME）。
    pub attachments: Vec<ImportedAttachment>,
    /// 非致命问题（例如跳过了不支持的标签），用于向用户报告。
    pub warnings: Vec<String>,
}

/// 导入过程中抽出的附件。
#[derive(Debug, Clone)]
pub struct ImportedAttachment {
    /// 原始文件名（仅展示用）。
    pub filename: String,
    /// 原始字节。
    pub bytes: Vec<u8>,
    /// 嗅探出的 MIME 类型。
    pub mime_type: String,
}

/// 导入层错误。
#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    /// 文件读取失败。
    #[error("读取导入文件失败：{0}")]
    Io(#[from] std::io::Error),

    /// 文件编码无法识别或转换失败。
    #[error("无法识别文件编码")]
    Encoding,

    /// 内容结构损坏。
    #[error("导入内容损坏：{reason}")]
    Corrupt {
        /// 具体原因。
        reason: String,
    },

    /// 格式不受支持。
    #[error("不支持的导入格式")]
    UnsupportedFormat,
}

/// 导入结果别名。
pub type ImportResult<T> = std::result::Result<T, ImportError>;
