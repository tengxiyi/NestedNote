//! # nested-server —— 同步服务可执行入口
//!
//! 职责：加载配置 → 初始化日志 → 连接依赖 → 执行迁移 → 启动 HTTP → 优雅停机。
//!
//! **禁止**在启动路径上做业务逻辑；业务在 `server-api` 及各领域 crate 中。
//!
//! ## 启动行为
//!
//! - 未配置 `DATABASE_URL`：**仍可启动**，但 `/readyz` 返回 503
//!   （便于本地只调 HTTP 层；生产环境应由编排系统拦住流量）。
//! - 配置了 `DATABASE_URL`：连接后**执行迁移**（结构变更走迁移，铁律 Q1）。
//! - 收到 Ctrl+C / SIGTERM：停止接受新连接，等待在途请求，超时强制退出。

#![forbid(unsafe_code)]

use std::process::ExitCode;

use server_api::{AppState, build_router};
use server_core::{Config, telemetry};
use server_storage::Database;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> ExitCode {
    telemetry::init_tracing();

    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            tracing::error!(error = %error, "服务启动失败");
            ExitCode::FAILURE
        }
    }
}

/// 启动流程。
async fn run() -> anyhow::Result<()> {
    let config = Config::from_env()?;
    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        protocol = protocol::PROTOCOL_VERSION,
        bind = %config.bind_addr,
        database_configured = config.has_database(),
        "启动 NestedNote 同步服务"
    );

    // 未配置数据库时**仍然启动**：便于本地只调 HTTP 层，
    // 但 /readyz 会如实返回 503，由编排系统决定是否导流。
    let database = if let Some(url) = &config.database_url {
        let database = Database::connect(url).await?;
        database.migrate().await?;
        tracing::info!("数据库已连接，迁移已执行");
        Some(database)
    } else {
        tracing::warn!("未配置 DATABASE_URL：服务可启动但不会就绪（/readyz 返回 503）");
        None
    };

    let state = AppState::new(config.clone(), database, None);
    let router = build_router(state);

    let listener = TcpListener::bind(config.bind_addr)
        .await
        .map_err(|error| anyhow::anyhow!("无法绑定 {}：{error}", config.bind_addr))?;
    let local = listener
        .local_addr()
        .map_err(|error| anyhow::anyhow!("无法读取监听地址：{error}"))?;
    tracing::info!(address = %local, "HTTP 服务已就绪");

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|error| anyhow::anyhow!("HTTP 服务异常退出：{error}"))?;

    tracing::info!("已优雅停机");
    Ok(())
}

/// 等待停机信号（Ctrl+C；Unix 上还包括 SIGTERM）。
async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(error) = tokio::signal::ctrl_c().await {
            tracing::error!(error = %error, "无法监听 Ctrl+C");
            // 监听失败时不要立刻停机，挂起等待
            std::future::pending::<()>().await;
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(error) => {
                tracing::error!(error = %error, "无法监听 SIGTERM");
                std::future::pending::<()>().await;
            }
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => tracing::info!("收到停止信号（Ctrl+C）"),
        () = terminate => tracing::info!("收到停止信号（SIGTERM）"),
    }
}
