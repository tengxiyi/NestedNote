//! # nested-sync —— 同步引擎（客户端侧）
//!
//! **状态**：P0 仅建立 crate 边界与设计约束；实现属于 P6（开发计划 §7）。
//!
//! ## 设计约束（已定）
//!
//! - **本地优先**（铁律 T3）：同步**永远**是后台行为，不得阻塞编辑或保存。
//! - **变更可追踪**（铁律 T6）：依托 `sync_operations` 队列，写操作与入队同事务。
//! - **禁止静默覆盖**（铁律 D10）：检测到分叉（同一笔记出现两个子修订）时，
//!   必须产生**用户可见**的冲突（冲突副本或冲突标记），不得自动取舍。
//! - **墓碑**（铁律 D9）：删除先本地软删 + 入队，附件 GC 必须等同步确认之后。
//! - **第一版不做 CRDT**（技术文档 §16/§17）：先做 Revision + Operation Log。

#![forbid(unsafe_code)]

use nested_model::Id;
use protocol::PROTOCOL_VERSION;

/// 本设备标识在设置表中的键名（值由 `nested-core` 首次启动时生成）。
pub const DEVICE_ID_SETTING_KEY: &str = "device.id";

/// 每个数据源的拉取游标在设置表中的键名前缀。
pub const PULL_CURSOR_KEY_PREFIX: &str = "sync.cursor.";

/// 同步阶段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncPhase {
    /// 空闲。
    Idle,
    /// 正在推送本地变更。
    Pushing,
    /// 正在拉取远端变更。
    Pulling,
    /// 正在同步附件。
    Attachments,
    /// 已完成一轮。
    Completed,
    /// 失败（网络、鉴权或数据冲突）。
    Failed,
}

/// 一次同步的结果摘要。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncReport {
    /// 推送成功的操作数。
    pub pushed: u32,
    /// 应用的远端变更数。
    pub pulled: u32,
    /// 上传的附件数。
    pub attachments_uploaded: u32,
    /// 下载的附件数。
    pub attachments_downloaded: u32,
    /// 探测到的冲突（笔记标识 + 两侧修订号）。
    pub conflicts: Vec<Conflict>,
    /// 结束时是否仍有待推送数据（离线或失败时会为 `true`）。
    pub pending_remaining: i64,
}

/// 一处并发修改冲突。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conflict {
    /// 发生冲突的笔记。
    pub note_id: Id,
    /// 本地侧最新修订号。
    pub local_version: i64,
    /// 远端侧最新修订号。
    pub remote_version: i64,
    /// 两侧的共同祖先修订号（用于判断是否真的分叉）。
    pub common_ancestor_version: Option<i64>,
}

/// 同步错误。
#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    /// 网络错误（超时、断连、DNS）。属于**可重试**错误。
    #[error("网络错误：{0}")]
    Network(String),

    /// 认证失败（token 失效或被吊销）。需要用户重新登录。
    #[error("认证失败")]
    Unauthorized,

    /// 服务端拒绝（配额、限流、版本不兼容）。
    #[error("服务端拒绝请求：{reason}")]
    Rejected {
        /// 原因描述。
        reason: String,
    },

    /// 协议版本不匹配。
    #[error("协议版本不匹配：服务端 {server}，客户端 {client}")]
    ProtocolMismatch {
        /// 服务端协议版本。
        server: u32,
        /// 客户端协议版本。
        client: u32,
    },

    /// 存储层错误。
    #[error("同步依赖的存储层出错：{0}")]
    Storage(#[from] nested_db::DbError),
}

impl SyncError {
    /// 是否值得自动重试（指数退避）。
    #[must_use]
    pub const fn is_retryable(&self) -> bool {
        matches!(self, Self::Network(_) | Self::Rejected { .. })
    }
}

/// 本客户端使用的协议版本。
#[must_use]
pub const fn client_protocol_version() -> u32 {
    PROTOCOL_VERSION
}

/// 同步结果别名。
pub type SyncResult<T> = std::result::Result<T, SyncError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_errors_are_retryable_but_auth_is_not() {
        assert!(SyncError::Network("timeout".to_owned()).is_retryable());
        assert!(!SyncError::Unauthorized.is_retryable());
    }

    #[test]
    fn protocol_version_comes_from_shared_contract() {
        assert_eq!(client_protocol_version(), protocol::PROTOCOL_VERSION);
    }

    #[test]
    fn device_id_key_is_stable() {
        assert_eq!(DEVICE_ID_SETTING_KEY, "device.id");
    }
}
