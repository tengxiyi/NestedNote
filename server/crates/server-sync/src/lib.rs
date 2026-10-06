//! # server-sync —— 同步服务端逻辑（P6 实现）
//!
//! **状态**：P0 仅建立边界与协议约束；实现在 P6（开发计划 §7）。
//!
//! ## 协议要点（第一版：Revision + Operation Log，不做 CRDT）
//!
//! - 客户端 push：一批操作 + 每条操作的父修订；服务端**必须**幂等去重（按操作 ID）；
//! - 客户端 pull：按 `(updated_at_ms, revision_id)` 游标增量拉取；
//! - 检测到分叉（同一笔记出现两个子修订）**必须**返回两侧修订，
//!   由客户端产生用户可见的冲突——服务端**禁止**自动取舍（铁律 D10）；
//! - 删除以墓碑（`deleted_at_ms`）同步，附件 GC 必须等所有已知设备确认（铁律 D9）；
//! - 所有响应**禁止**包含其他用户的数据，鉴权在查询层强制（铁律 S6）。

#![forbid(unsafe_code)]

use protocol::PROTOCOL_VERSION;

/// 单次 push 允许的最大操作数（防止一次请求打爆事务，铁律 S8）。
pub const MAX_PUSH_OPERATIONS: usize = 500;

/// 单次 pull 默认返回的修订数上限。
pub const DEFAULT_PULL_LIMIT: u32 = 200;

/// 单次 pull 允许的最大修订数。
pub const MAX_PULL_LIMIT: u32 = 1000;

/// 同步服务端错误。
#[derive(Debug, thiserror::Error)]
pub enum SyncServerError {
    /// 协议版本不兼容。
    #[error("协议版本不兼容：服务端 {server}，客户端 {client}")]
    ProtocolMismatch {
        /// 服务端协议版本。
        server: u32,
        /// 客户端协议版本。
        client: u32,
    },

    /// 请求参数不合法。
    #[error("同步请求无效：{0}")]
    BadRequest(String),

    /// 存储层错误。
    #[error("同步存储错误：{0}")]
    Storage(#[from] server_storage::StorageError),

    /// 尚未实现（P6 交付）。
    #[error("同步功能尚未实现（计划阶段 P6）")]
    NotImplemented,
}

/// 校验客户端协议版本。
///
/// # Errors
///
/// 版本不一致时返回 [`SyncServerError::ProtocolMismatch`]。
pub fn check_protocol(client_version: u32) -> Result<(), SyncServerError> {
    if client_version == PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(SyncServerError::ProtocolMismatch {
            server: PROTOCOL_VERSION,
            client: client_version,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_protocol_is_accepted() {
        assert!(check_protocol(PROTOCOL_VERSION).is_ok());
    }

    #[test]
    fn mismatched_protocol_is_rejected() {
        let error = check_protocol(PROTOCOL_VERSION + 1).expect_err("must reject");
        assert!(matches!(error, SyncServerError::ProtocolMismatch { .. }));
    }

    #[test]
    fn limits_are_bounded() {
        // 铁律 S8：单次请求的操作数与返回量必须有硬上限。
        // 通过变量中转，让断言在运行期求值（常量断言会被 clippy 判定为无意义）。
        let max_push = MAX_PUSH_OPERATIONS;
        let default_pull = DEFAULT_PULL_LIMIT;
        let max_pull = MAX_PULL_LIMIT;
        assert!(max_push > 0 && max_push <= 1000, "推送批量必须有上限");
        assert!(default_pull <= max_pull, "默认拉取量不得超过上限");
    }
}
