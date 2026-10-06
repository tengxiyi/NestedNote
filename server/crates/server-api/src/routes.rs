//! HTTP 路由与处理器。
//!
//! ## 端点（P0）
//!
//! | 方法 | 路径 | 说明 |
//! |---|---|---|
//! | GET | `/healthz` | 存活探测：进程活着即 200。**不**检查依赖 |
//! | GET | `/readyz` | 就绪探测：依赖（数据库、对象存储）全部可用才 200，否则 503 |
//! | GET | `/api/v1/version` | 版本与协议版本，供客户端握手 |
//!
//! **区分这两个探测是有意为之**：把依赖故障当成"进程死亡"会让编排系统
//! 反复重启一个其实健康的进程，把小故障放大成雪崩。

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::get;
use axum::{Json, Router};
use protocol::{
    API_PREFIX, HealthResponse, PROTOCOL_VERSION, ReadyResponse, SERVER_NAME, VersionResponse,
};
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::trace::TraceLayer;

use crate::state::AppState;

/// 构建应用路由。
pub fn build_router(state: AppState) -> Router {
    let max_body = state.config().max_body_bytes;

    let api = Router::new()
        .route("/version", get(version))
        .with_state(state.clone());

    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .nest(API_PREFIX, api)
        .fallback(not_found)
        .layer(RequestBodyLimitLayer::new(max_body))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// `GET /healthz` —— 存活探测。
async fn healthz() -> Json<HealthResponse> {
    Json(HealthResponse::default())
}

/// `GET /readyz` —— 就绪探测。
async fn readyz(State(state): State<AppState>) -> (StatusCode, Json<ReadyResponse>) {
    let checks = state.readiness_checks().await;
    let ready = checks.iter().all(|(_, ok)| *ok);
    let status = if ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (status, Json(ReadyResponse { ready, checks }))
}

/// `GET /api/v1/version` —— 版本与协议握手信息。
async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        name: SERVER_NAME,
        version: env!("CARGO_PKG_VERSION"),
        protocol_version: PROTOCOL_VERSION,
        server_time_ms: server_time_ms(),
    })
}

/// 当前 UTC 毫秒时间。
fn server_time_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

/// 未匹配路由：返回结构化 404，而不是空响应体。
async fn not_found() -> (StatusCode, Json<protocol::ErrorResponse>) {
    (
        StatusCode::NOT_FOUND,
        Json(protocol::ErrorResponse::new(
            "NOT_FOUND",
            "请求的接口不存在。",
        )),
    )
}
