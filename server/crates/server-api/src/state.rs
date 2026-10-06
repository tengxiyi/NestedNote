//! 应用状态：配置 + 依赖句柄。
//!
//! 依赖用 `Option` 表达"可选"，从而让服务在**没有数据库**的情况下也能启动，
//! 但 `/readyz` 会如实报告未就绪（铁律 E6：状态必须诚实，禁止假装健康）。

use std::sync::Arc;
use std::time::Instant;

use server_core::Config;
use server_storage::Database;
use server_storage::s3::ObjectStore;

/// 共享应用状态。
#[derive(Debug, Clone)]
pub struct AppState {
    inner: Arc<Inner>,
}

/// 状态内部结构（`Arc` 便于在 handler 间零成本克隆）。
#[derive(Debug)]
struct Inner {
    config: Config,
    database: Option<Database>,
    object_store: Option<Arc<dyn ObjectStore>>,
    started: Instant,
}

impl AppState {
    /// 构造状态。
    #[must_use]
    pub fn new(
        config: Config,
        database: Option<Database>,
        object_store: Option<Arc<dyn ObjectStore>>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                config,
                database,
                object_store,
                started: Instant::now(),
            }),
        }
    }

    /// 配置。
    #[must_use]
    pub fn config(&self) -> &Config {
        &self.inner.config
    }

    /// 数据库句柄（未配置时为 `None`）。
    #[must_use]
    pub fn database(&self) -> Option<&Database> {
        self.inner.database.as_ref()
    }

    /// 对象存储（未配置时为 `None`）。
    #[must_use]
    pub fn object_store(&self) -> Option<&Arc<dyn ObjectStore>> {
        self.inner.object_store.as_ref()
    }

    /// 进程已运行时长（秒）。
    #[must_use]
    pub fn uptime_secs(&self) -> u64 {
        self.inner.started.elapsed().as_secs()
    }

    /// 执行依赖就绪检查，返回逐项结果。
    ///
    /// 语义与 `/readyz` 一致：**只看依赖**，不看进程是否活着（那是 `/healthz`）。
    pub async fn readiness_checks(&self) -> Vec<(String, bool)> {
        let database_ok = match self.database() {
            Some(database) => database.ping().await.is_ok(),
            None => false,
        };
        vec![
            ("postgres".to_owned(), database_ok),
            (
                "object_store_configured".to_owned(),
                self.object_store().is_some(),
            ),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;
    use std::time::Duration;

    fn test_config() -> Config {
        Config {
            bind_addr: "127.0.0.1:0".parse::<SocketAddr>().expect("valid"),
            database_url: None,
            shutdown_timeout: Duration::from_secs(1),
            max_body_bytes: 1024,
        }
    }

    #[tokio::test]
    async fn state_without_dependencies_reports_not_ready() {
        let state = AppState::new(test_config(), None, None);
        let checks = state.readiness_checks().await;
        assert!(
            checks.iter().all(|(_, ok)| !ok),
            "没有依赖时必须如实报告未就绪，而不是假装健康"
        );
    }

    #[test]
    fn uptime_starts_at_zero() {
        let state = AppState::new(test_config(), None, None);
        assert!(state.uptime_secs() < 5);
    }
}
