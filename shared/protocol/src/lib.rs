//! # protocol —— 跨端唯一共享的纯数据契约
//!
//! 本 crate 是客户端与服务端**唯一**允许共享的代码（技术文档 §4.2 硬约束 2）。
//!
//! ## 铁律约束
//!
//! - **禁止**引入任何 IO / 数据库 / 网络 / 加密依赖（这里只允许 `serde` 与 `thiserror`）。
//! - **禁止**放置业务规则；这里只有**数据结构与常量**。
//! - 任何字段改动都影响两端 → 必须走 ADR（铁律 A10 / M2）。
//!
//! ## 为什么不把 DTO 放在各自仓库里
//!
//! 两端各写一份 DTO 会产生"看起来能编译，实际上字段悄悄漂移"的经典故障。
//! 共享一份纯数据定义，漂移会在编译期暴露。

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};

/// 协议版本：客户端与服务端握手时比较（不匹配时服务端应返回 426 或兼容降级）。
///
/// 版本策略：破坏性变更 +1；仅新增可选字段不变更。
pub const PROTOCOL_VERSION: u32 = 1;

/// HTTP API 前缀（技术文档 §19：API 必须版本化）。
pub const API_PREFIX: &str = "/api/v1";

/// 服务端名称，用于 `/api/v1/version` 与日志字段。
pub const SERVER_NAME: &str = "nested-server";

/// 客户端名称，用于 `User-Agent` 与同步握手。
pub const CLIENT_NAME: &str = "NestedNote";

/// 存活探测响应体（`GET /healthz`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthResponse {
    /// 固定为 `"ok"`；进程活着就返回。
    pub status: &'static str,
}

impl Default for HealthResponse {
    fn default() -> Self {
        Self { status: "ok" }
    }
}

/// 就绪探测响应体（`GET /readyz`）。
///
/// 与 [`HealthResponse`] 的区别：`/healthz` 只看进程是否活着，
/// `/readyz` 必须确认**依赖就绪**（数据库、对象存储），否则负载均衡不应导流。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct ReadyResponse {
    /// 总体是否就绪。
    pub ready: bool,
    /// 各依赖项的状态，例如 `("postgres", true)`。
    ///
    /// 用 `String` 而非 `&'static str`：后者无法反序列化（借用检查不允许把
    /// 反序列化出来的数据当作 `'static`），而客户端需要能解析这个响应。
    pub checks: Vec<(String, bool)>,
}

/// 版本信息响应体（`GET /api/v1/version`）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionResponse {
    /// 服务端名称。
    pub name: &'static str,
    /// 服务端版本（Cargo 包版本）。
    pub version: &'static str,
    /// 协议版本，见 [`PROTOCOL_VERSION`]。
    pub protocol_version: u32,
    /// 探测时间（UTC Unix 毫秒）。
    pub server_time_ms: i64,
}

/// 统一错误响应体（技术文档 §33：不向客户端暴露内部细节）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorResponse {
    /// 稳定错误码（大写下划线，可被客户端分支处理），如 `NOT_FOUND`。
    pub code: String,
    /// 面向用户的可读信息（**禁止**含 SQL、堆栈、内部路径，铁律 E2）。
    pub message: String,
    /// 可选的请求 ID，用于在服务端日志中检索同一次请求（铁律 E3）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

impl ErrorResponse {
    /// 构造一个不含请求 ID 的错误响应。
    #[must_use]
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            request_id: None,
        }
    }

    /// 附加请求 ID。
    #[must_use]
    pub fn with_request_id(mut self, request_id: impl Into<String>) -> Self {
        self.request_id = Some(request_id.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_response_serializes_as_expected() {
        let json = serde_json::to_string(&HealthResponse::default()).expect("serialize");
        assert_eq!(json, r#"{"status":"ok"}"#);
    }

    #[test]
    fn ready_response_uses_snake_case() {
        let json = serde_json::to_string(&ReadyResponse {
            ready: true,
            checks: vec![("postgres".to_owned(), true)],
        })
        .expect("serialize");
        assert_eq!(json, r#"{"ready":true,"checks":[["postgres",true]]}"#);

        // 必须能反序列化：客户端要解析这个响应
        let back: ReadyResponse = serde_json::from_str(&json).expect("deserialize");
        assert!(back.ready);
        assert_eq!(back.checks.len(), 1);
    }

    #[test]
    fn error_response_omits_absent_request_id() {
        let json = serde_json::to_string(&ErrorResponse::new("NOT_FOUND", "笔记不存在"))
            .expect("serialize");
        assert!(!json.contains("request_id"), "request_id 应被省略：{json}");
    }

    #[test]
    fn protocol_version_is_positive() {
        assert!(PROTOCOL_VERSION >= 1);
    }
}
