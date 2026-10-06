//! 服务端错误类型。
//!
//! 两类错误，职责不同：
//!
//! - [`ServerError`]：启动期与内部错误（可以带技术细节，只进日志）；
//! - [`ApiError`]：HTTP 边界错误，**必须**转成 [`protocol::ErrorResponse`]，
//!   禁止把内部细节暴露给客户端（铁律 E2）。

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use protocol::ErrorResponse;
use thiserror::Error;

/// 服务端内部错误。
#[derive(Debug, Error)]
pub enum ServerError {
    /// 配置错误。
    #[error("配置错误：{0}")]
    Config(String),

    /// 数据库错误。
    #[error("数据库错误：{0}")]
    Database(String),

    /// 迁移失败。
    #[error("迁移失败：{0}")]
    Migration(String),

    /// 网络/绑定错误。
    #[error("网络错误：{0}")]
    Network(String),

    /// 未实现（明确占位，禁止用它掩盖半成品）。
    #[error("尚未实现：{0}")]
    NotImplemented(&'static str),
}

/// HTTP 边界错误。
#[derive(Debug, Error)]
pub enum ApiError {
    /// 请求体或参数不合法。
    #[error("请求无效：{0}")]
    BadRequest(String),

    /// 未认证。
    #[error("未认证")]
    Unauthorized,

    /// 无权限。
    #[error("无权限")]
    Forbidden,

    /// 资源不存在。
    #[error("资源不存在")]
    NotFound,

    /// 冲突（并发修改、唯一约束）。
    #[error("冲突：{0}")]
    Conflict(String),

    /// 请求体过大。
    #[error("请求体过大")]
    PayloadTooLarge,

    /// 依赖未就绪（数据库等）。
    #[error("服务未就绪：{0}")]
    NotReady(String),

    /// 服务端内部错误（细节只进日志，不返回给客户端）。
    #[error("内部错误")]
    Internal(#[from] ServerError),
}

impl ApiError {
    /// 对应的 HTTP 状态码。
    #[must_use]
    pub const fn status(&self) -> StatusCode {
        match self {
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized => StatusCode::UNAUTHORIZED,
            Self::Forbidden => StatusCode::FORBIDDEN,
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Conflict(_) => StatusCode::CONFLICT,
            Self::PayloadTooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Self::NotReady(_) => StatusCode::SERVICE_UNAVAILABLE,
            Self::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    /// 稳定错误码（客户端可分支处理，铁律 E3）。
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::BadRequest(_) => "BAD_REQUEST",
            Self::Unauthorized => "UNAUTHORIZED",
            Self::Forbidden => "FORBIDDEN",
            Self::NotFound => "NOT_FOUND",
            Self::Conflict(_) => "CONFLICT",
            Self::PayloadTooLarge => "PAYLOAD_TOO_LARGE",
            Self::NotReady(_) => "NOT_READY",
            Self::Internal(_) => "INTERNAL_ERROR",
        }
    }

    /// 面向客户端的可读信息。
    ///
    /// 内部错误**绝不**回显具体原因（可能含 SQL、路径、连接串）。
    #[must_use]
    pub fn client_message(&self) -> String {
        match self {
            Self::BadRequest(reason) | Self::Conflict(reason) | Self::NotReady(reason) => {
                reason.clone()
            }
            Self::Unauthorized => "请先登录。".to_owned(),
            Self::Forbidden => "没有权限执行该操作。".to_owned(),
            Self::NotFound => "请求的内容不存在。".to_owned(),
            Self::PayloadTooLarge => "请求内容过大。".to_owned(),
            Self::Internal(_) => "服务器内部错误，请稍后重试。".to_owned(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        // 内部错误要留下日志痕迹，便于排查；但日志与响应体都不得含敏感数据（铁律 S3）
        if let Self::Internal(inner) = &self {
            tracing::error!(error = %inner, "请求处理失败");
        }
        let status = self.status();
        let body = ErrorResponse::new(self.code(), self.client_message());
        (status, Json(body)).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn internal_errors_do_not_leak_details() {
        let error = ApiError::Internal(ServerError::Database(
            "connection string postgres://user:secret@host/db".to_owned(),
        ));
        let message = error.client_message();
        assert!(!message.contains("postgres"));
        assert!(!message.contains("secret"));
        assert_eq!(message, "服务器内部错误，请稍后重试。");
    }

    #[test]
    fn status_and_code_mapping_is_consistent() {
        assert_eq!(ApiError::Unauthorized.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(ApiError::Unauthorized.code(), "UNAUTHORIZED");
        assert_eq!(ApiError::NotFound.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            ApiError::PayloadTooLarge.status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );
        assert_eq!(
            ApiError::Internal(ServerError::NotImplemented("x")).status(),
            StatusCode::INTERNAL_SERVER_ERROR
        );
    }

    #[test]
    fn not_ready_is_service_unavailable() {
        assert_eq!(
            ApiError::NotReady("postgres".to_owned()).status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            ApiError::NotReady("postgres".to_owned()).code(),
            "NOT_READY"
        );
    }
}
