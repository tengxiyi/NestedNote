//! # nested-attachment —— 附件与内容寻址存储
//!
//! ## 为什么用内容寻址（Content Addressable Storage）
//!
//! 文件名不是标识：同一张图被改名、被复制、被粘贴进两篇笔记，都是**同一份内容**。
//! 因此路径由内容哈希决定（铁律 T8），带来四个直接好处：
//!
//! 1. **自动去重**：相同内容只落盘一份；
//! 2. **完整性可校验**：路径本身就是期望哈希，读完可以验；
//! 3. **同步友好**：跨设备传输以哈希为键，天然幂等、可断点续传；
//! 4. **对象存储兼容**：S3 的 key 直接用同一个哈希（见 `server-storage`）。
//!
//! 目录布局（与《技术文档》§9 一致，两级分片避免单目录文件过多）：
//!
//! ```text
//! attachments/
//! └── 8f/
//!     └── 14/
//!         └── 8f14e45fceea167a5a36dedd4bea2543...
//! ```
//!
//! ## 铁律约束
//!
//! | 铁律 | 在本模块的体现 |
//! |---|---|
//! | T8 文件不进数据库 | 只落盘文件；元数据由 `nested-db::repositories::attachments` 负责 |
//! | D3 原子落盘 | 写临时文件 → fsync → rename，**绝不**直接写目标路径 |
//! | D4 写后校验 | 写入后回读并核对 SHA-256 |
//! | S6 不信任文件名 | 哈希由内容计算，与文件名无关 |
//! | S7 防路径穿越 | 路径由哈希推导，哈希格式先校验 |
//! | P7 主线程禁止重活 | 哈希与拷贝用流式读写，大文件不进内存 |
//! | R1 禁止 panic | 全部返回结构化错误，非法哈希也不 panic |

#![forbid(unsafe_code)]

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// 附件存储根目录的约定名称（位于应用数据目录之下）。
pub const ATTACHMENTS_DIR: &str = "attachments";

/// 缩略图缓存目录名。
pub const THUMBNAILS_DIR: &str = "cache/thumbs";

/// SHA-256 十六进制串的长度。
pub const SHA256_HEX_LEN: usize = 64;

/// 流式读写的缓冲区大小（64 KiB）：兼顾系统调用次数与内存占用。
const COPY_BUFFER_BYTES: usize = 64 * 1024;

/// 计算字节内容的 SHA-256（小写十六进制）。
#[must_use]
pub fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    to_hex(&hasher.finalize())
}

/// 流式计算文件的 SHA-256（小写十六进制）。
///
/// **流式**而非一次读入：附件可能是 GB 级文件，整读进内存会直接违反内存预算（铁律 P7）。
///
/// # Errors
///
/// 文件不存在或读取失败时返回 [`AttachmentError::Io`]。
pub fn hash_file(path: &Path) -> AttachmentResult<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; COPY_BUFFER_BYTES];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(to_hex(&hasher.finalize()))
}

/// 校验哈希串是否为合法的 64 位小写十六进制。
///
/// 拒绝大写：存储层与数据库索引统一使用小写，
/// 否则同一份内容会出现两个不同的键，去重就失效了。
#[must_use]
pub fn is_valid_hash(hash: &str) -> bool {
    hash.len() == SHA256_HEX_LEN
        && hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// 字节数组转小写十六进制。
fn to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    out
}

/// 内容寻址存储。
#[derive(Debug, Clone)]
pub struct ContentStore {
    /// 存储根目录。
    root: PathBuf,
}

/// 一次写入的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredBlob {
    /// 内容 SHA-256（小写十六进制）。
    pub sha256: String,
    /// 字节数。
    pub size_bytes: u64,
    /// 最终落盘路径。
    pub path: PathBuf,
    /// 是否命中了已有内容（`true` 表示本次没有真正写盘，去重生效）。
    pub deduplicated: bool,
}

impl ContentStore {
    /// 以给定根目录构造（不会创建目录，首次写入时才创建）。
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
    /// # Errors
    ///
    /// 哈希格式非法时返回 [`AttachmentError::InvalidHash`]。
    ///
    /// **为什么不 panic**：哈希虽然通常来自本模块计算，但也可能来自数据库
    /// 或同步对端。对不可信输入必须返回错误（铁律 S6/R1）。
    pub fn path_for(&self, sha256: &str) -> AttachmentResult<PathBuf> {
        if !is_valid_hash(sha256) {
            return Err(AttachmentError::InvalidHash {
                hash: sha256.to_owned(),
            });
        }
        Ok(self
            .root
            .join(&sha256[0..2])
            .join(&sha256[2..4])
            .join(sha256))
    }

    /// 内容是否已存在。
    ///
    /// # Errors
    ///
    /// 哈希格式非法时返回 [`AttachmentError::InvalidHash`]。
    pub fn contains(&self, sha256: &str) -> AttachmentResult<bool> {
        Ok(self.path_for(sha256)?.is_file())
    }

    /// 写入一段内容，返回其哈希与落盘信息。
    ///
    /// 流程（每一步都对应一条铁律）：
    ///
    /// 1. 计算内容哈希（决定路径）；
    /// 2. 若目标已存在 → 直接返回 `deduplicated = true`（去重，铁律 T8）；
    /// 3. 否则建目录 → 写**临时文件** → `fsync` → `rename` 到目标（原子，铁律 D3）；
    /// 4. 回读并核对哈希（铁律 D4）。
    ///
    /// # Errors
    ///
    /// - 目录或文件操作失败 → [`AttachmentError::Io`]
    /// - 写入后校验不一致 → [`AttachmentError::HashMismatch`]
    pub fn put_bytes(&self, bytes: &[u8]) -> AttachmentResult<StoredBlob> {
        let sha256 = hash_bytes(bytes);
        let target = self.path_for(&sha256)?;

        if target.is_file() {
            tracing::debug!(sha256 = %sha256, "附件已存在，跳过写入（内容寻址去重）");
            return Ok(StoredBlob {
                sha256,
                size_bytes: bytes.len() as u64,
                path: target,
                deduplicated: true,
            });
        }

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let temp_path = self.temp_path_for(&sha256);
        {
            let mut file = std::fs::File::create(&temp_path)?;
            file.write_all(bytes)?;
            // fsync：确保数据真正落盘后再 rename，断电也不会出现"名字有了、内容是空的"
            file.sync_all()?;
        }
        commit_temp(&temp_path, &target)?;

        let actual = hash_file(&target)?;
        if actual != sha256 {
            // 校验失败说明磁盘写入不可信：删掉坏文件，让调用方重试或报错
            let _ = std::fs::remove_file(&target);
            return Err(AttachmentError::HashMismatch {
                expected: sha256,
                actual,
            });
        }

        Ok(StoredBlob {
            sha256,
            size_bytes: bytes.len() as u64,
            path: target,
            deduplicated: false,
        })
    }

    /// 从文件写入内容（流式，不整读进内存）。
    ///
    /// # Errors
    ///
    /// - 源文件读取失败 → [`AttachmentError::Io`]
    /// - 写入后校验不一致 → [`AttachmentError::HashMismatch`]
    pub fn put_file(&self, source: &Path) -> AttachmentResult<StoredBlob> {
        let sha256 = hash_file(source)?;
        let size_bytes = std::fs::metadata(source)?.len();
        let target = self.path_for(&sha256)?;

        if target.is_file() {
            return Ok(StoredBlob {
                sha256,
                size_bytes,
                path: target,
                deduplicated: true,
            });
        }

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let temp_path = self.temp_path_for(&sha256);
        {
            let mut input = std::fs::File::open(source)?;
            let mut output = std::fs::File::create(&temp_path)?;
            let mut buffer = vec![0_u8; COPY_BUFFER_BYTES];
            loop {
                let read = input.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                output.write_all(&buffer[..read])?;
            }
            output.sync_all()?;
        }
        commit_temp(&temp_path, &target)?;

        let actual = hash_file(&target)?;
        if actual != sha256 {
            let _ = std::fs::remove_file(&target);
            return Err(AttachmentError::HashMismatch {
                expected: sha256,
                actual,
            });
        }

        Ok(StoredBlob {
            sha256,
            size_bytes,
            path: target,
            deduplicated: false,
        })
    }

    /// 读取内容。
    ///
    /// # Errors
    ///
    /// - 哈希非法 → [`AttachmentError::InvalidHash`]
    /// - 文件不存在 → [`AttachmentError::NotFound`]
    /// - 内容与哈希不符 → [`AttachmentError::HashMismatch`]
    pub fn read(&self, sha256: &str) -> AttachmentResult<Vec<u8>> {
        let path = self.path_for(sha256)?;
        if !path.is_file() {
            return Err(AttachmentError::NotFound {
                sha256: sha256.to_owned(),
            });
        }
        let bytes = std::fs::read(&path)?;
        let actual = hash_bytes(&bytes);
        if actual != sha256 {
            return Err(AttachmentError::HashMismatch {
                expected: sha256.to_owned(),
                actual,
            });
        }
        Ok(bytes)
    }

    /// 校验已落盘内容是否与哈希一致（用于定期体检与备份前校验）。
    ///
    /// # Errors
    ///
    /// - 哈希非法 → [`AttachmentError::InvalidHash`]
    /// - 文件缺失 → [`AttachmentError::NotFound`]
    /// - 内容不符 → [`AttachmentError::HashMismatch`]
    pub fn verify(&self, sha256: &str) -> AttachmentResult<()> {
        let path = self.path_for(sha256)?;
        if !path.is_file() {
            return Err(AttachmentError::NotFound {
                sha256: sha256.to_owned(),
            });
        }
        let actual = hash_file(&path)?;
        if actual == sha256 {
            Ok(())
        } else {
            Err(AttachmentError::HashMismatch {
                expected: sha256.to_owned(),
                actual,
            })
        }
    }

    /// 物理删除内容。
    ///
    /// ## 调用者必须先确认"无人引用"
    ///
    /// 本方法**不做引用检查**：引用计数在数据库里（`note_attachments`），
    /// 属于仓储层的职责。GC 流程必须先确认 `ref_count == 0` 且墓碑期已过
    /// （铁律 T7/D2/D9），否则会删掉别的笔记正在用的附件。
    ///
    /// # Errors
    ///
    /// 哈希非法或删除失败时返回错误；文件本就不存在时视为成功（幂等）。
    pub fn delete(&self, sha256: &str) -> AttachmentResult<()> {
        let path = self.path_for(sha256)?;
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(AttachmentError::Io(error)),
        }
    }

    /// 临时文件路径。
    ///
    /// 放在**同一目录**下（而不是系统临时目录）：`rename` 只有在同一文件系统内
    /// 才是原子的，跨设备会退化成"复制 + 删除"，失去 D3 的保证。
    fn temp_path_for(&self, sha256: &str) -> PathBuf {
        let parent = self.root.join(&sha256[0..2]).join(&sha256[2..4]);
        parent.join(format!(".{sha256}.tmp"))
    }
}

/// 把临时文件提交为目标文件（原子操作）。
///
/// Windows 上 `rename` 在目标已存在时会失败，因此目标存在时先删除。
/// 这只影响"并发写同一内容"的极小概率场景，且此时内容必然相同。
fn commit_temp(temp_path: &Path, target: &Path) -> AttachmentResult<()> {
    if target.exists() {
        std::fs::remove_file(target)?;
    }
    std::fs::rename(temp_path, target)?;
    Ok(())
}

/// 附件层错误。
#[derive(Debug, thiserror::Error)]
pub enum AttachmentError {
    /// 文件系统错误。
    #[error("附件文件操作失败：{0}")]
    Io(#[from] std::io::Error),

    /// 存储层错误（元数据操作）。
    #[error("附件元数据操作失败：{0}")]
    Storage(#[from] nested_db::DbError),

    /// 哈希格式非法（长度不是 64 或含非小写十六进制字符）。
    #[error("非法的内容哈希：{hash}")]
    InvalidHash {
        /// 传入的哈希串。
        hash: String,
    },

    /// 内容不存在。
    #[error("附件内容不存在：{sha256}")]
    NotFound {
        /// 内容哈希。
        sha256: String,
    },

    /// 写入或读取后校验发现内容不一致（磁盘故障或并发篡改）。
    #[error("附件内容校验失败：期望 {expected}，实际 {actual}")]
    HashMismatch {
        /// 期望的 SHA-256。
        expected: String,
        /// 实际计算得到的 SHA-256。
        actual: String,
    },
}

/// 附件结果别名。
pub type AttachmentResult<T> = std::result::Result<T, AttachmentError>;

#[cfg(test)]
mod tests {
    use super::*;

    /// 已知向量：空内容的 SHA-256。
    const EMPTY_HASH: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    fn store() -> (ContentStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        (ContentStore::new(dir.path().join("attachments")), dir)
    }

    #[test]
    fn hash_matches_known_vectors() {
        assert_eq!(hash_bytes(b""), EMPTY_HASH);
        assert_eq!(
            hash_bytes(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn hash_is_lowercase_hex_of_64_chars() {
        let hash = hash_bytes(b"hello world");
        assert_eq!(hash.len(), SHA256_HEX_LEN);
        assert!(is_valid_hash(&hash));
    }

    #[test]
    fn hash_validation_rejects_uppercase_and_bad_length() {
        assert!(!is_valid_hash(""));
        assert!(!is_valid_hash("abc"));
        assert!(!is_valid_hash(&"a".repeat(63)));
        assert!(!is_valid_hash(&"a".repeat(65)));
        // 大写必须拒绝：否则同一内容会有两个键，去重失效
        assert!(!is_valid_hash(&"A".repeat(64)));
        assert!(!is_valid_hash(&"g".repeat(64)));
        assert!(is_valid_hash(&"0123456789abcdef".repeat(4)));
    }

    #[test]
    fn hash_file_equals_hash_bytes() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("sample.bin");
        let content = b"file content for hashing";
        std::fs::write(&path, content).expect("write");
        assert_eq!(hash_file(&path).expect("hash"), hash_bytes(content));
    }

    #[test]
    fn hash_file_streams_large_content() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("big.bin");
        // 1 MiB + 17 字节：跨越多个读缓冲，验证流式读取不丢内容
        let content = vec![0x5a_u8; 1024 * 1024 + 17];
        std::fs::write(&path, &content).expect("write");
        assert_eq!(hash_file(&path).expect("hash"), hash_bytes(&content));
    }

    #[test]
    fn hash_file_reports_missing_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let error = hash_file(&dir.path().join("nope.bin")).expect_err("must fail");
        assert!(matches!(error, AttachmentError::Io(_)));
    }

    #[test]
    fn path_uses_two_level_sharding() {
        let (store, _dir) = store();
        let hash = hash_bytes(b"sharding");
        let path = store.path_for(&hash).expect("path");
        let relative = path
            .strip_prefix(store.root())
            .expect("under root")
            .to_string_lossy()
            .replace('\\', "/");
        assert_eq!(
            relative,
            format!("{}/{}/{}", &hash[0..2], &hash[2..4], hash)
        );
    }

    #[test]
    fn path_rejects_invalid_hash() {
        let (store, _dir) = store();
        assert!(matches!(
            store.path_for("not-a-hash").expect_err("must fail"),
            AttachmentError::InvalidHash { .. }
        ));
    }

    #[test]
    fn put_bytes_writes_and_reads_back() {
        let (store, _dir) = store();
        let content = b"hello attachment";
        let blob = store.put_bytes(content).expect("put");
        assert!(!blob.deduplicated);
        assert_eq!(blob.size_bytes, content.len() as u64);
        assert!(blob.path.is_file());
        assert_eq!(store.read(&blob.sha256).expect("read"), content);
        store.verify(&blob.sha256).expect("verify");
    }

    #[test]
    fn same_content_is_deduplicated() {
        let (store, _dir) = store();
        let first = store.put_bytes(b"duplicate me").expect("first");
        let second = store.put_bytes(b"duplicate me").expect("second");

        assert!(!first.deduplicated, "首次写入应真正落盘");
        assert!(second.deduplicated, "相同内容不应重复落盘");
        assert_eq!(first.sha256, second.sha256);
        assert_eq!(first.path, second.path);
    }

    #[test]
    fn different_content_goes_to_different_paths() {
        let (store, _dir) = store();
        let a = store.put_bytes(b"content a").expect("a");
        let b = store.put_bytes(b"content b").expect("b");
        assert_ne!(a.sha256, b.sha256);
        assert_ne!(a.path, b.path);
        assert_eq!(store.read(&a.sha256).expect("read a"), b"content a");
        assert_eq!(store.read(&b.sha256).expect("read b"), b"content b");
    }

    #[test]
    fn empty_content_is_supported() {
        let (store, _dir) = store();
        let blob = store.put_bytes(b"").expect("put empty");
        assert_eq!(blob.sha256, EMPTY_HASH);
        assert_eq!(blob.size_bytes, 0);
        assert_eq!(store.read(&blob.sha256).expect("read"), b"");
    }

    #[test]
    fn no_temp_file_left_behind_after_success() {
        let (store, _dir) = store();
        let blob = store.put_bytes(b"no leftovers").expect("put");
        let parent = blob.path.parent().expect("parent");
        let leftovers: Vec<_> = std::fs::read_dir(parent)
            .expect("read dir")
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "成功写入后不应残留临时文件");
    }

    #[test]
    fn contains_reports_presence() {
        let (store, _dir) = store();
        let hash = hash_bytes(b"presence");
        assert!(!store.contains(&hash).expect("contains"));
        store.put_bytes(b"presence").expect("put");
        assert!(store.contains(&hash).expect("contains"));
    }

    #[test]
    fn read_missing_content_is_not_found() {
        let (store, _dir) = store();
        let hash = hash_bytes(b"never stored");
        assert!(matches!(
            store.read(&hash).expect_err("must fail"),
            AttachmentError::NotFound { .. }
        ));
    }

    #[test]
    fn verify_detects_corrupted_content() {
        let (store, _dir) = store();
        let blob = store.put_bytes(b"will be corrupted").expect("put");
        // 模拟磁盘损坏：把内容改掉但保持文件名（即哈希）不变
        std::fs::write(&blob.path, b"tampered content here").expect("tamper");
        let error = store
            .verify(&blob.sha256)
            .expect_err("must detect corruption");
        assert!(matches!(error, AttachmentError::HashMismatch { .. }));
    }

    #[test]
    fn read_detects_corrupted_content() {
        let (store, _dir) = store();
        let blob = store.put_bytes(b"read then corrupt").expect("put");
        std::fs::write(&blob.path, b"different bytes").expect("tamper");
        assert!(matches!(
            store
                .read(&blob.sha256)
                .expect_err("must detect corruption"),
            AttachmentError::HashMismatch { .. }
        ));
    }

    #[test]
    fn put_file_round_trips_and_deduplicates() {
        let (store, dir) = store();
        let source = dir.path().join("source.bin");
        let content = vec![7_u8; 200_000];
        std::fs::write(&source, &content).expect("write source");

        let first = store.put_file(&source).expect("first");
        assert!(!first.deduplicated);
        assert_eq!(first.size_bytes, 200_000);
        assert_eq!(store.read(&first.sha256).expect("read"), content);

        // 同一内容换个文件名再来一次：必须命中已有内容
        let copy = dir.path().join("renamed.bin");
        std::fs::write(&copy, &content).expect("write copy");
        let second = store.put_file(&copy).expect("second");
        assert!(second.deduplicated);
        assert_eq!(first.path, second.path);
    }

    #[test]
    fn put_file_reports_missing_source() {
        let (store, dir) = store();
        let error = store
            .put_file(&dir.path().join("missing.bin"))
            .expect_err("must fail");
        assert!(matches!(error, AttachmentError::Io(_)));
    }

    #[test]
    fn delete_is_idempotent() {
        let (store, _dir) = store();
        let blob = store.put_bytes(b"delete me").expect("put");
        store.delete(&blob.sha256).expect("first delete");
        assert!(!store.contains(&blob.sha256).expect("contains"));
        // 再删一次不应报错（GC 可能重试）
        store.delete(&blob.sha256).expect("second delete");
    }

    #[test]
    fn layout_matches_attachment_storage_key() {
        // 交叉验证：本模块的路径布局必须与 nested-model 的 storage_key() 一致，
        // 否则数据库里存的 sha256 会指向不存在的文件。
        let (store, _dir) = store();
        let hash = hash_bytes(b"cross-check");
        let attachment =
            nested_model::Attachment::new(hash.clone(), "application/octet-stream", 11, "x.bin", 0)
                .expect("valid attachment");

        let from_store = store.path_for(&hash).expect("path");
        let from_model = store.root().join(attachment.storage_key());
        assert_eq!(
            from_store, from_model,
            "ContentStore 与 Attachment::storage_key 的布局必须一致"
        );
    }
}
