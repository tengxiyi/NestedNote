//! 内核错误（铁律 E1：对 UI 暴露**结构化**错误，不抛 stack trace）。
//!
//! 每个变体都提供一个稳定的 `code()`，供 UI 分支处理与日志检索（铁律 E3）。

use thiserror::Error;

/// 内核错误。
#[derive(Debug, Error)]
pub enum CoreError {
    /// 数据库错误。
    #[error("数据库错误：{0}")]
    Database(#[from] nested_db::DbError),

    /// 领域模型校验错误。
    #[error("数据校验失败：{0}")]
    Validation(#[from] nested_model::ModelError),

    /// 请求的数据不存在。
    #[error("找不到指定的{entity}")]
    NotFound {
        /// 实体名称。
        entity: &'static str,
    },

    /// 配置错误（数据目录不可用、参数非法等）。
    #[error("配置错误：{0}")]
    Config(String),

    /// 冲突（唯一约束、并发修改）。
    #[error("数据冲突：{0}")]
    Conflict(String),

    /// 权限不足（文件系统或平台权限）。
    #[error("权限不足：{0}")]
    Permission(String),

    /// 网络错误（同步相关）。
    #[error("网络错误：{0}")]
    Network(String),

    /// 功能尚未实现（P0 阶段的明确占位，**禁止**用来掩盖半成品）。
    #[error("功能尚未实现：{0}")]
    NotImplemented(&'static str),
}

impl CoreError {
    /// 稳定错误码（UI 与日志共用，铁律 E3）。
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Database(_) => "DATABASE_ERROR",
            Self::Validation(_) => "VALIDATION_ERROR",
            Self::NotFound { .. } => "NOT_FOUND",
            Self::Config(_) => "CONFIG_ERROR",
            Self::Conflict(_) => "CONFLICT",
            Self::Permission(_) => "PERMISSION_ERROR",
            Self::Network(_) => "NETWORK_ERROR",
            Self::NotImplemented(_) => "NOT_IMPLEMENTED",
        }
    }

    /// 该错误是否值得自动重试。
    #[must_use]
    pub const fn is_retryable(&self) -> bool {
        matches!(self, Self::Network(_) | Self::Conflict(_))
    }

    /// 面向用户的简短建议（UI 直接展示，**不含**内部细节，铁律 E2）。
    #[must_use]
    pub const fn user_hint(&self) -> &'static str {
        match self {
            Self::Database(_) => "请尝试重启应用；若问题持续，请从备份恢复数据。",
            Self::Validation(_) => "请检查输入内容后重试。",
            Self::NotFound { .. } => "该内容可能已被删除或移动。",
            Self::Config(_) => "请检查设置中的数据目录是否可写。",
            Self::Conflict(_) => "内容已被其他设备修改，请查看冲突副本。",
            Self::Permission(_) => "请授予所需权限后重试。",
            Self::Network(_) => "请检查网络连接后重试。",
            Self::NotImplemented(_) => "该功能将在后续版本提供。",
        }
    }
}

/// 内核结果别名。
pub type CoreResult<T> = std::result::Result<T, CoreError>;

#[cfg(test)]
mod tests {
    use super::*;
    use nested_model::ModelError;

    #[test]
    fn codes_are_stable_and_unique() {
        let samples = [
            CoreError::Database(nested_db::DbError::NotFound { entity: "note" }),
            CoreError::Validation(ModelError::InvalidId),
            CoreError::NotFound { entity: "note" },
            CoreError::Config("x".to_owned()),
            CoreError::Conflict("x".to_owned()),
            CoreError::Permission("x".to_owned()),
            CoreError::Network("x".to_owned()),
            CoreError::NotImplemented("sync"),
        ];
        let mut codes: Vec<&str> = samples.iter().map(CoreError::code).collect();
        let total = codes.len();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), total, "错误码必须互不重复");
    }

    #[test]
    fn retryability_is_conservative() {
        assert!(CoreError::Network("timeout".to_owned()).is_retryable());
        assert!(!CoreError::NotImplemented("sync").is_retryable());
        assert!(!CoreError::Validation(ModelError::InvalidId).is_retryable());
    }

    #[test]
    fn hints_never_leak_internals() {
        let error = CoreError::Database(nested_db::DbError::Sqlite(rusqlite::Error::InvalidQuery));
        let hint = error.user_hint();
        assert!(!hint.contains("SQL"), "用户提示不得出现内部术语：{hint}");
        assert!(!hint.contains("rusqlite"));
    }
}
