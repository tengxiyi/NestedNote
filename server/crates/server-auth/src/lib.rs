//! # server-auth —— 认证与设备（P6 实现）
//!
//! **状态**：P0 仅建立边界与安全约束；实现在 P6（开发计划 §7.1）。
//!
//! ## 硬约束（实现时不得偏离）
//!
//! - 口令**必须**用 Argon2id 哈希（当前无依赖，故 P0 不实现）；
//! - refresh token **只存哈希**，明文只在签发响应中出现一次（铁律 S3）；
//! - 认证失败**禁止**区分"用户不存在"与"口令错误"，避免账号枚举；
//! - 登录接口**必须**限流（铁律 S8）；
//! - 所有 token 校验失败**必须**返回 401 且不泄露原因。

#![forbid(unsafe_code)]

/// access token 的默认有效期（秒）。
pub const ACCESS_TOKEN_TTL_SECS: i64 = 15 * 60;

/// refresh token 的默认有效期（秒，30 天）。
pub const REFRESH_TOKEN_TTL_SECS: i64 = 30 * 24 * 60 * 60;

/// 认证错误。
#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    /// 凭据无效（**不区分**账号不存在与口令错误）。
    #[error("凭据无效")]
    InvalidCredentials,

    /// token 过期。
    #[error("token 已过期")]
    TokenExpired,

    /// token 非法或已被吊销。
    #[error("token 非法")]
    InvalidToken,

    /// 设备已被吊销。
    #[error("设备已被吊销")]
    DeviceRevoked,

    /// 存储层错误。
    #[error("认证存储错误：{0}")]
    Storage(#[from] server_storage::StorageError),

    /// 尚未实现（P6 交付）。
    #[error("认证功能尚未实现（计划阶段 P6）")]
    NotImplemented,
}

/// 认证结果别名。
pub type AuthResult<T> = std::result::Result<T, AuthError>;
