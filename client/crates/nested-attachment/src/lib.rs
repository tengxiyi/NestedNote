//! # nested-attachment —— 附件与内容寻址存储
//!
//! **状态**：P0 仅建立 crate 边界；实现属于 P1（开发计划 §2.1.4）。
//!
//! ## 设计要点（已定，实现时不得偏离）
//!
//! - 存储路径由内容哈希决定：`attachments/<前2位>/<次2位>/<完整 SHA-256>`（铁律 T8）；
//! - 写入必须"临时文件 → fsync → rename"，**禁止**直接写目标路径（铁律 D3）；
//! - 写完必须回读校验哈希（铁律 D4）；
//! - 文件名不参与标识，仅用于展示；
//! - 无引用附件先变墓碑，保留期之后才允许 GC（铁律 T7 / D9）。

#![forbid(unsafe_code)]

use std::path::{Path, PathBuf};

/// 附件存储根目录的约定名称（位于应用数据目录之下）。
pub const ATTACHMENTS_DIR: &str = "attachments";

/// 缩略图缓存目录名。
pub const THUMBNAILS_DIR: &str = "cache/thumbs";

/// 内容寻址存储。
#[derive(Debug, Clone)]
pub struct ContentStore {
    /// 存储根目录。
    root: PathBuf,
}

impl ContentStore {
    /// 以给定根目录构造。
    #[must_use]
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// 存储根目录。
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// 由内容哈希推导存储路径：`<前2位>/<次2位>/<完整哈希>`。
    ///
    /// 与 [`nested_model::Attachment::storage_key`] 保持一致：两级分片避免单目录文件过多。
    #[must_use]
    pub fn path_for(&self, sha256: &str) -> PathBuf {
        if sha256.len() < 4 {
            // 非法哈希不可能来自 Attachment（构造时已校验长度），
            // 这里退化为根目录下的原样文件名而不是 panic（铁律 R1）。
            return self.root.join(sha256);
        }
        self.root
            .join(&sha256[0..2])
            .join(&sha256[2..4])
            .join(sha256)
    }
}

/// 附件层错误。
#[derive(Debug, thiserror::Error)]
pub enum AttachmentError {
    /// 文件系统错误。
    #[error("附件文件操作失败：{0}")]
    Io(#[from] std::io::Error),

    /// 存储层错误。
    #[error("附件元数据操作失败：{0}")]
    Storage(#[from] nested_db::DbError),

    /// 写入后校验发现内容不一致（磁盘故障或并发篡改）。
    #[error("附件内容校验失败：期望 {expected}，实际 {actual}")]
    HashMismatch {
        /// 期望的 SHA-256。
        expected: String,
        /// 实际计算得到的 SHA-256。
        actual: String,
    },

    /// 文件名非法或路径越界（铁律 S7）。
    #[error("非法的附件路径")]
    InvalidPath,
}

/// 附件结果别名。
pub type AttachmentResult<T> = std::result::Result<T, AttachmentError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_uses_two_level_sharding() {
        let store = ContentStore::new("data");
        let hash = "8f14e45fceea167a5a36dedd4bea2543".to_owned() + &"0".repeat(32);
        let path = store.path_for(&hash);
        assert!(path.ends_with(Path::new(&hash)));
        assert!(path.to_string_lossy().contains("8f"));
    }

    #[test]
    fn short_hash_does_not_panic() {
        let store = ContentStore::new("data");
        assert_eq!(store.path_for("ab"), Path::new("data").join("ab"));
    }
}
