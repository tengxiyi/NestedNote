//! 对象存储抽象（S3 兼容 / 本地文件）。
//!
//! **状态**：P0 仅定义接口；实现属于 P6（开发计划 §7.1，配合 MinIO 开发）。
//!
//! ## 设计要点
//!
//! - 附件在对象存储中的键**必须**是内容哈希（与客户端 CAS 一致，铁律 T8），
//!   这样上传天然幂等、可去重、可断点续传；
//! - 上传前**必须**校验大小与哈希（铁律 D4）；
//! - **禁止**把用户的原始文件名当作对象键（会导致重名覆盖与路径注入）。

use async_trait::async_trait;

use crate::StorageResult;

/// 对象存储后端。
#[async_trait]
pub trait ObjectStore: std::fmt::Debug + Send + Sync {
    /// 写入对象（键为内容哈希）。
    ///
    /// 若对象已存在且哈希一致，实现**应当**直接返回成功（幂等）。
    async fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()>;

    /// 读取对象。
    async fn get(&self, key: &str) -> StorageResult<Vec<u8>>;

    /// 对象是否存在。
    async fn exists(&self, key: &str) -> StorageResult<bool>;

    /// 删除对象。
    async fn delete(&self, key: &str) -> StorageResult<()>;
}

/// 由内容哈希推导对象键。
///
/// 与客户端 `nested_model::Attachment::storage_key` 保持同一约定：
/// `<前2位>/<次2位>/<完整哈希>`。
#[must_use]
pub fn object_key_for_sha256(sha256: &str) -> String {
    if sha256.len() < 4 {
        return sha256.to_owned();
    }
    format!("{}/{}/{}", &sha256[0..2], &sha256[2..4], sha256)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_layout_matches_client_cas() {
        let hash = "8f14e45fceea167a5a36dedd4bea2543".to_owned() + &"0".repeat(32);
        assert_eq!(object_key_for_sha256(&hash), format!("8f/14/{hash}"));
    }

    #[test]
    fn short_key_does_not_panic() {
        assert_eq!(object_key_for_sha256("ab"), "ab");
    }
}
