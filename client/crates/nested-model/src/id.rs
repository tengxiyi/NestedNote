//! 标识符类型与生成规则（铁律 D7）。

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// 全局唯一、时间有序的标识符。
///
/// 使用 UUIDv7：前 48 位是毫秒时间戳，因此天然按创建时间排序，
/// 既适合做主键（B-tree 局部性好），又天然适合多设备生成而无需协调。
///
/// **禁止**用自增整数或文件名/标题充当标识（铁律 D7）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Id(Uuid);

impl Id {
    /// 生成一个新的 UUIDv7 标识。
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::now_v7())
    }

    /// 从已有的 UUID 构造（用于从数据库读取或跨端传输）。
    #[must_use]
    pub const fn from_uuid(uuid: Uuid) -> Self {
        Self(uuid)
    }

    /// 解析字符串形式的标识（例如从 JSON、URL 或数据库 TEXT 列读取）。
    ///
    /// # Errors
    ///
    /// 字符串不是合法 UUID 时返回 [`crate::ModelError::InvalidId`]。
    pub fn parse(text: &str) -> crate::Result<Self> {
        Uuid::parse_str(text)
            .map(Self)
            .map_err(|_| crate::ModelError::InvalidId)
    }

    /// 取出底层 UUID。
    #[must_use]
    pub const fn as_uuid(&self) -> Uuid {
        self.0
    }

    /// 字节数组视图（用于 SQLite BLOB 存储）。
    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 16] {
        self.0.as_bytes()
    }

    /// 从 16 字节数组还原。
    ///
    /// # Errors
    ///
    /// 字节非法时（几乎不可能）返回 [`crate::ModelError::InvalidId`]。
    pub fn from_slice(bytes: &[u8]) -> crate::Result<Self> {
        Uuid::from_slice(bytes)
            .map(Self)
            .map_err(|_| crate::ModelError::InvalidId)
    }
}

impl Default for Id {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for Id {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_ids_are_unique() {
        let a = Id::new();
        let b = Id::new();
        assert_ne!(a, b);
    }

    #[test]
    fn roundtrip_through_string_and_bytes() {
        let id = Id::new();
        assert_eq!(Id::parse(&id.to_string()).expect("parse"), id);
        assert_eq!(Id::from_slice(id.as_bytes()).expect("from_slice"), id);
    }

    #[test]
    fn invalid_text_is_rejected() {
        assert!(Id::parse("not-a-uuid").is_err());
    }
}
