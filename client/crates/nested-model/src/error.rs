//! 领域模型错误类型（铁律 R3：库层用 `thiserror` 定义具体错误，不用 `String` 向上传播）。

use thiserror::Error;

/// 模型层错误。
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ModelError {
    /// 标识符不是合法 UUID。
    #[error("非法标识符：不是合法的 UUID")]
    InvalidId,

    /// 时间戳超出可表示范围。
    #[error("非法时间戳：超出可表示范围")]
    InvalidTimestamp,

    /// 文档格式版本不受支持（升级/降级场景）。
    #[error("不支持的文档格式版本：{found}（当前支持到 {supported}）")]
    UnsupportedDocumentVersion {
        /// 文档中记录的版本号。
        found: u32,
        /// 本程序支持的版本号。
        supported: u32,
    },

    /// 字段违反领域约束（长度、范围、计数等）。
    #[error("字段校验失败：{field} —— {reason}")]
    Validation {
        /// 出错的字段名。
        field: &'static str,
        /// 人类可读的原因。
        reason: &'static str,
    },
}

/// 模型层 Result 别名。
pub type Result<T> = std::result::Result<T, ModelError>;
