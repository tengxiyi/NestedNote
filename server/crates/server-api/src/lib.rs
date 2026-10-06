//! # server-api —— HTTP 层
//!
//! Axum 路由、中间件与请求/响应 DTO。业务规则不在这里（铁律 A7），
//! 这里只做：解析请求 → 调用领域逻辑 → 映射为 HTTP 响应。
//!
//! ## 分层
//!
//! ```text
//! HTTP 请求 → server-api（本 crate）
//!               ├── server-auth     认证与设备（P6）
//!               ├── server-sync     同步逻辑（P6）
//!               └── server-storage  PostgreSQL / 对象存储
//! ```
//!
//! ## 典型用法
//!
//! ```
//! use server_api::{AppState, build_router};
//! use server_core::Config;
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let config = Config::from_env()?;
//! let state = AppState::new(config, None, None);
//! let _router = build_router(state);
//! # Ok(())
//! # }
//! ```

#![forbid(unsafe_code)]

pub mod routes;
pub mod state;

pub use routes::build_router;
pub use state::AppState;

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use server_core::Config;
    use std::net::SocketAddr;
    use std::time::Duration;
    use tower::ServiceExt;

    fn test_state() -> AppState {
        let config = Config {
            bind_addr: "127.0.0.1:0".parse::<SocketAddr>().expect("valid"),
            database_url: None,
            shutdown_timeout: Duration::from_secs(1),
            max_body_bytes: 1024,
        };
        AppState::new(config, None, None)
    }

    /// 用 `tower::ServiceExt::oneshot` 直接调用路由，无需真实监听端口。
    async fn call(path: &str) -> (StatusCode, String) {
        let router = build_router(test_state());
        let response = router
            .oneshot(
                Request::builder()
                    .uri(path)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

    #[tokio::test]
    async fn healthz_is_ok_even_without_dependencies() {
        let (status, body) = call("/healthz").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, r#"{"status":"ok"}"#);
    }

    #[tokio::test]
    async fn readyz_is_unavailable_without_dependencies() {
        let (status, body) = call("/readyz").await;
        assert_eq!(
            status,
            StatusCode::SERVICE_UNAVAILABLE,
            "无数据库时必须报告未就绪"
        );
        assert!(body.contains("\"ready\":false"), "body = {body}");
        assert!(body.contains("postgres"));
    }

    #[tokio::test]
    async fn version_reports_protocol() {
        let (status, body) = call("/api/v1/version").await;
        assert_eq!(status, StatusCode::OK);
        assert!(body.contains(protocol::SERVER_NAME));
        assert!(body.contains(&format!(
            "\"protocol_version\":{}",
            protocol::PROTOCOL_VERSION
        )));
        assert!(body.contains("\"server_time_ms\""));
    }

    #[tokio::test]
    async fn unknown_route_returns_structured_404() {
        let (status, body) = call("/api/v1/nope").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert!(body.contains("NOT_FOUND"), "必须是结构化错误：{body}");
    }

    #[tokio::test]
    async fn health_and_ready_are_not_under_api_prefix() {
        // 探测端点必须与业务 API 分离：编排系统不应依赖业务路由
        assert_eq!(call("/healthz").await.0, StatusCode::OK);
        assert_eq!(call("/api/v1/healthz").await.0, StatusCode::NOT_FOUND);
    }
}
