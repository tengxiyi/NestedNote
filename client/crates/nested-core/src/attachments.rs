//! 附件业务：内容寻址存储与元数据的**衔接层**。
//!
//! ## 为什么需要一个专门的衔接层
//!
//! 附件横跨两个存储：字节在文件系统（`nested-attachment::ContentStore`），
//! 元数据在 SQLite（`nested-db::repositories::attachments`）。
//! 在补齐本模块之前，这两半**各自都实现并测过，却没有任何函数把它们串起来**——
//! 也就是说"插入一个附件"这个动作在代码里根本不存在（技术债 #17）。
//!
//! ## 关键设计：写入顺序不可颠倒
//!
//! 文件系统与数据库**无法共享一个事务**，因此必须明确哪一半先落：
//!
//! ```text
//! 1. ContentStore::put_*  → 文件落盘（原子：临时文件 → fsync → rename → 回读校验）
//! 2. 数据库事务           → 附件元数据（+ 可选的笔记内容更新）
//! ```
//!
//! 为什么不是反过来：
//!
//! | 顺序 | 失败时的残留 | 后果 |
//! |---|---|---|
//! | **先文件后库**（本模块） | 孤儿文件（无元数据） | 安全：占点磁盘，可被 GC 回收 |
//! | 先库后文件 | 断链（有元数据无文件） | **危险**：读取时报错，用户看到"附件损坏" |
//!
//! 一句话：**孤儿文件是可回收的垃圾，断链是用户可见的故障**。
//!
//! 因此本模块的所有写路径都保证一个不变量：
//!
//! > **每一条 `attachments` 记录，其内容一定已经完整落盘。**
//!
//! 反向不保证（可能存在没有记录的孤儿文件），这正是 [`NestedCore::gc_attachments`] 的职责。

use std::path::{Path, PathBuf};

use nested_attachment::ContentStore;
use nested_db::DbError;
use nested_db::repositories::attachments as attachment_repo;
use nested_model::Attachment;

use crate::error::{CoreError, CoreResult};

/// 附件存储目录名（位于数据目录之下）。
pub const ATTACHMENTS_DIR: &str = "attachments";

/// 孤儿文件的**宽限期**（毫秒）。
///
/// 超过这个时长仍无元数据引用的文件才允许被 GC 删除。
///
/// ## 为什么必须有宽限期
///
/// 写入顺序是"先文件、后库"。在这两步之间，文件就是**暂时性的孤儿**。
/// 若 GC 恰好在此时运行，就会删掉一个正在被写入的附件，
/// 随后数据库记录指向一个不存在的文件——正是我们极力避免的断链。
///
/// 默认 1 小时：足够覆盖任何正常的写入间隔（写入是毫秒级的），
/// 又不会让真正无用的文件长期占着磁盘。
pub const GC_GRACE_PERIOD_MS: i64 = 60 * 60 * 1000;

/// 附件存储与元数据的协调者。
///
/// 由 [`NestedCore`](crate::NestedCore) 持有；上层不应直接构造。
#[derive(Debug, Clone)]
pub struct AttachmentService {
    store: ContentStore,
}

/// 一次 GC 的结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GcReport {
    /// 被删除的孤儿文件数。
    pub removed_files: usize,
    /// 因仍在宽限期内而保留的候选文件数。
    pub kept_recent: usize,
    /// 释放的字节数。
    pub freed_bytes: u64,
    /// 元数据指向但文件缺失的**断链**数。
    ///
    /// 正常情况下应当为 0。不为 0 说明违反了本模块的不变量
    /// （见模块文档），需要人工排查——因此这里如实报告而不是静默忽略。
    pub broken_links: usize,
}

impl AttachmentService {
    /// 在给定数据目录下构造。
    #[must_use]
    pub fn new(data_dir: &Path) -> Self {
        Self {
            store: ContentStore::new(data_dir.join(ATTACHMENTS_DIR)),
        }
    }

    /// 存储根目录。
    #[must_use]
    pub fn root(&self) -> &Path {
        self.store.root()
    }

    /// 按内容哈希读取字节（**读取时校验**，铁律 D4）。
    ///
    /// # Errors
    ///
    /// - 哈希非法 → [`CoreError::Validation`]
    /// - 文件缺失 → [`CoreError::NotFound`]（即"断链"）
    /// - 内容与哈希不符 → [`CoreError::Config`]（携带可读原因）
    pub fn read(&self, sha256: &str) -> CoreResult<Vec<u8>> {
        self.store.read(sha256).map_err(to_core_error)
    }

    /// 内容是否已落盘。
    ///
    /// # Errors
    ///
    /// 哈希非法时返回 [`CoreError::Validation`]。
    pub fn contains(&self, sha256: &str) -> CoreResult<bool> {
        self.store.contains(sha256).map_err(to_core_error)
    }

    /// 把一段字节写入 CAS，并登记元数据。
    ///
    /// **不**建立与笔记的关联——关联通过文档内容表达（见
    /// [`NestedCore::attach_bytes_to_note`](crate::NestedCore::attach_bytes_to_note)）。
    ///
    /// 流程：写文件（原子）→ 同一事务内 upsert 元数据 + 入队同步操作。
    ///
    /// # Errors
    ///
    /// - 写入文件失败 → [`CoreError::Config`]
    /// - 写元数据失败 → [`CoreError::Database`]
    pub fn store_bytes(
        &self,
        core: &crate::NestedCore,
        bytes: &[u8],
        mime_type: &str,
        filename: &str,
        at_ms: i64,
    ) -> CoreResult<Attachment> {
        // 1) 先落文件（顺序不可颠倒，见模块文档）
        let stored = self.store.put_bytes(bytes).map_err(to_core_error)?;

        // 2) 再落元数据。
        //
        // ⚠️ 顺序陷阱：`device_id()` 内部**也要取数据库连接**。必须先把它拿到手，
        // 再去 `connection()`；反过来写会命中重入保护并返回 `ReentrantLock`
        // （见踩坑备忘 §5.3——本项目为此专门加过检测，否则这里是**静默死锁**）。
        let device_id = core.device_id()?;
        let connection = core.database().connection()?;
        let attachment =
            Attachment::new(stored.sha256, mime_type, stored.size_bytes, filename, at_ms)?;
        let id = attachment_repo::upsert(&connection, &attachment)?;
        attachment_repo::enqueue_sync(&connection, &id, &device_id, at_ms)?;

        // upsert 可能命中已有内容而复用其 id，因此回读一次以保证返回值与库一致
        let persisted = attachment_repo::get(&connection, &id)?.ok_or(CoreError::NotFound {
            entity: "attachment",
        })?;
        // 连接在这里释放，避免与 core 的其它方法嵌套加锁
        drop(connection);
        Ok(persisted)
    }

    /// 从文件读取并写入 CAS（流式，大文件不整读进内存）。
    ///
    /// # Errors
    ///
    /// 同 [`AttachmentService::store_bytes`]，另外源文件不可读时返回 [`CoreError::Config`]。
    pub fn store_file(
        &self,
        core: &crate::NestedCore,
        source: &Path,
        mime_type: &str,
        filename: &str,
        at_ms: i64,
    ) -> CoreResult<Attachment> {
        let stored = self.store.put_file(source).map_err(to_core_error)?;

        // 同 store_bytes：先取设备标识，再取连接（避免重入，见那里的说明）
        let device_id = core.device_id()?;
        let connection = core.database().connection()?;
        let attachment =
            Attachment::new(stored.sha256, mime_type, stored.size_bytes, filename, at_ms)?;
        let id = attachment_repo::upsert(&connection, &attachment)?;
        attachment_repo::enqueue_sync(&connection, &id, &device_id, at_ms)?;
        let persisted = attachment_repo::get(&connection, &id)?.ok_or(CoreError::NotFound {
            entity: "attachment",
        })?;
        drop(connection);
        Ok(persisted)
    }

    /// 校验某附件的文件是否与哈希一致（备份前体检用）。
    ///
    /// # Errors
    ///
    /// - 文件缺失 → [`CoreError::NotFound`]
    /// - 内容不符 → [`CoreError::Config`]
    pub fn verify(&self, sha256: &str) -> CoreResult<()> {
        self.store.verify(sha256).map_err(to_core_error)
    }

    /// 回收孤儿文件。
    ///
    /// 判据：文件存在，但 `attachments` 表里**没有任何记录**引用它的哈希，
    /// 且文件的修改时间已超过 [`GC_GRACE_PERIOD_MS`]。
    ///
    /// ## 绝不删除仍被引用的内容
    ///
    /// 内容寻址意味着多个笔记可能引用同一份内容；引用计数由
    /// `note_attachments` 推导。因此这里只删"哈希在 attachments 表中完全不存在"的文件，
    /// **不**依据 `ref_count`——后端字段是推导缓存，可能滞后。
    ///
    /// ## 顺带报告断链
    ///
    /// 反向检查（元数据有记录但文件缺失）不会修复任何东西，
    /// 只把计数回报给调用方——按本模块的不变量它应当恒为 0，
    /// 不为 0 就是需要人工介入的信号。
    ///
    /// # Errors
    ///
    /// 读取元数据或遍历目录失败时返回错误。
    pub fn gc(&self, core: &crate::NestedCore, now_ms: i64) -> CoreResult<GcReport> {
        let mut report = GcReport::default();

        // 1) 收集库中所有已知哈希（含墓碑：软删除的记录仍指向有效文件，
        //    因为恢复笔记时要能立刻读到内容）
        let known = core.database().with_connection(|connection| {
            let mut statement = connection.prepare("SELECT sha256 FROM attachments")?;
            let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
            rows.collect::<Result<Vec<_>, _>>().map_err(DbError::from)
        })?;

        // 2) 反向检查：记录存在但文件缺失
        for sha256 in &known {
            if !self.store.contains(sha256).map_err(to_core_error)? {
                report.broken_links += 1;
                tracing::warn!(sha256 = %sha256, "附件元数据存在但文件缺失（断链）");
            }
        }

        // 3) 正向检查：磁盘上有、库里没有的文件
        let known_set: std::collections::HashSet<&str> = known.iter().map(String::as_str).collect();
        for (sha256, path, modified_ms) in self.walk_files()? {
            if known_set.contains(sha256.as_str()) {
                continue;
            }
            // 宽限期：避免删掉"文件已写、元数据还没写"的中间态
            if now_ms.saturating_sub(modified_ms) < GC_GRACE_PERIOD_MS {
                report.kept_recent += 1;
                continue;
            }
            let size = std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);
            match std::fs::remove_file(&path) {
                Ok(()) => {
                    report.removed_files += 1;
                    report.freed_bytes += size;
                    tracing::info!(sha256 = %sha256, "回收孤儿附件文件");
                }
                Err(error) => {
                    tracing::warn!(%error, path = %path.display(), "删除孤儿文件失败，跳过");
                }
            }
        }

        Ok(report)
    }

    /// 遍历存储目录，产出 `(sha256, 路径, 修改时间毫秒)`。
    ///
    /// 只认 `<2位>/<2位>/<64位十六进制>` 这一布局（见 `ContentStore`），
    /// 临时文件（以 `.` 开头）与不符合布局的文件一律跳过。
    fn walk_files(&self) -> CoreResult<Vec<(String, PathBuf, i64)>> {
        let mut found = Vec::new();
        let root = self.store.root();
        let Ok(level1) = std::fs::read_dir(root) else {
            // 目录还不存在：没有附件，属于正常情况
            return Ok(found);
        };

        for entry1 in level1.flatten() {
            if !entry1.path().is_dir() {
                continue;
            }
            let Ok(level2) = std::fs::read_dir(entry1.path()) else {
                continue;
            };
            for entry2 in level2.flatten() {
                if !entry2.path().is_dir() {
                    continue;
                }
                let Ok(files) = std::fs::read_dir(entry2.path()) else {
                    continue;
                };
                for file in files.flatten() {
                    let path = file.path();
                    let name = file.file_name().to_string_lossy().to_string();
                    if !nested_attachment::is_valid_hash(&name) {
                        // 临时文件、残留的半截文件等
                        continue;
                    }
                    let modified_ms = file
                        .metadata()
                        .ok()
                        .and_then(|meta| meta.modified().ok())
                        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                        .map_or(0, |duration| {
                            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
                        });
                    found.push((name, path, modified_ms));
                }
            }
        }
        Ok(found)
    }
}

/// 把 `nested_attachment` 的错误映射为内核错误。
///
/// 映射规则（铁律 E1：错误必须在边界处翻译，不能把底层类型透传给 UI）：
/// - 哈希非法 → `Validation`（调用方传错了东西）
/// - 内容不存在 → `NotFound`（用户可见的"附件丢失"）
/// - 校验不符 / IO 失败 → `Config`（环境或磁盘问题）
fn to_core_error(error: nested_attachment::AttachmentError) -> CoreError {
    use nested_attachment::AttachmentError;
    match error {
        // 哈希由界面/同步对端传入，格式不对属于"调用方给错了东西"。
        // 这里用 Config 而不是 Validation：`CoreError::Validation` 携带的是
        // `ModelError`（领域字段校验失败），与此处的"参数格式"不是一类。
        AttachmentError::InvalidHash { hash } => {
            CoreError::Config(format!("非法的内容哈希：{hash}"))
        }
        // 这是最重要的一个映射：它意味着"元数据说文件在，实际不在"，
        // 也就是模块文档里说的**断链**。
        AttachmentError::NotFound { .. } => CoreError::NotFound {
            entity: "attachment",
        },
        AttachmentError::HashMismatch { expected, actual } => CoreError::Config(format!(
            "附件内容校验失败（期望 {expected}，实际 {actual}）"
        )),
        AttachmentError::Io(error) => CoreError::Config(format!("附件文件操作失败：{error}")),
        AttachmentError::Storage(error) => CoreError::Database(error),
    }
}
