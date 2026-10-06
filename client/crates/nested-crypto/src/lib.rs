//! # nested-crypto —— 加密与平台密钥存储
//!
//! **状态**：P0 仅建立 crate 边界与**硬约束**；具体方案待 ADR 决定后于 P1 实现。
//!
//! ## 不可协商的约束（铁律 D11 / S2）
//!
//! - 密钥**绝不**以明文写入数据库、配置文件、日志或仓库。
//! - 密钥**必须**存放在平台安全存储：
//!   Windows Credential Manager ｜ macOS / iOS Keychain ｜ Android Keystore。
//! - 任何"为了方便先放进 settings 表"的做法都属于**必须拒绝**的变更。
//!
//! ## 待决策问题（写入 ADR 后再实现）
//!
//! | 问题 | 候选 | 影响 |
//! |---|---|---|
//! | 数据库加密方式 | SQLCipher（整库） ｜ 字段级加密 ｜ 不加密 + 全盘加密 | 整库加密会改变驱动与迁移方式 |
//! | 附件加密 | 逐文件加密后入库 ｜ 明文 + 依赖磁盘加密 | 影响 CAS 去重（同内容不同密文） |
//! | 密钥派生 | Argon2id ｜ 平台密钥 + 用户口令组合 | 影响解锁体验与安全强度 |

#![forbid(unsafe_code)]

/// 密钥在平台安全存储中的服务名。
pub const KEYCHAIN_SERVICE: &str = "app.nestednote";

/// 主密钥条目的账户名。
pub const MASTER_KEY_ACCOUNT: &str = "master-key";

/// 平台安全存储抽象。
///
/// 实现必须按平台调用原生 API；**禁止**用文件或数据库做降级存储。
pub trait SecretStore: std::fmt::Debug {
    /// 读取密钥；不存在时返回 `Ok(None)`。
    ///
    /// # Errors
    ///
    /// 平台 API 失败时返回实现自定义错误（以字符串形式向上传递，
    /// 由 `nested-core` 映射为结构化错误）。
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, String>;

    /// 写入/覆盖密钥。
    ///
    /// # Errors
    ///
    /// 平台 API 失败时返回错误。
    fn set(&self, account: &str, secret: &[u8]) -> Result<(), String>;

    /// 删除密钥。
    ///
    /// # Errors
    ///
    /// 平台 API 失败时返回错误（密钥不存在不算失败）。
    fn delete(&self, account: &str) -> Result<(), String>;
}

/// 加密层错误。
#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    /// 平台安全存储不可用。
    #[error("平台安全存储不可用：{0}")]
    SecretStoreUnavailable(String),

    /// 密钥不存在（需要用户先解锁或重新登录）。
    #[error("密钥不存在")]
    KeyMissing,

    /// 加解密失败（密文损坏或密钥不匹配）。
    #[error("加解密失败")]
    DecryptionFailed,

    /// 方案尚未实现（P0 占位）。
    #[error("加密功能尚未实现（待 ADR 决定方案）")]
    NotImplemented,
}

/// 加密结果别名。
pub type CryptoResult<T> = std::result::Result<T, CryptoError>;
