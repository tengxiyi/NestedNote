//! 服务端配置。
//!
//! **规则**：所有配置来自环境变量，且**禁止**把机密写入代码或仓库（铁律 S1 / B8）。
//! 缺失关键配置时**必须**启动失败并说明原因，禁止用默认值悄悄跑起来（生产尤甚）。

use std::net::SocketAddr;
use std::time::Duration;

use crate::error::ServerError;

/// 服务端配置。
#[derive(Debug, Clone)]
pub struct Config {
    /// 监听地址（默认 `0.0.0.0:8080`）。
    pub bind_addr: SocketAddr,
    /// PostgreSQL 连接串。
    pub database_url: Option<String>,
    /// 优雅停机最長等待时间。
    pub shutdown_timeout: Duration,
    /// 单次请求体大小上限（字节），防止大体积上传打爆内存（铁律 S8）。
    pub max_body_bytes: usize,
}

impl Config {
    /// 默认监听地址。
    pub const DEFAULT_BIND: &'static str = "0.0.0.0:8080";

    /// 默认请求体上限：16 MiB（附件同步走独立的对象存储通道，不走这个接口）。
    pub const DEFAULT_MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

    /// 从环境变量加载配置。
    ///
    /// 识别的变量：
    /// - `NESTED_BIND_ADDR`（默认 `0.0.0.0:8080`）
    /// - `DATABASE_URL`（可选；未设置时 `/readyz` 会报告数据库未就绪）
    /// - `NESTED_MAX_BODY_BYTES`
    ///
    /// # Errors
    ///
    /// 地址或数值无法解析时返回 [`ServerError::Config`]。
    pub fn from_env() -> Result<Self, ServerError> {
        let bind_raw =
            std::env::var("NESTED_BIND_ADDR").unwrap_or_else(|_| Self::DEFAULT_BIND.to_owned());
        let bind_addr = bind_raw.parse::<SocketAddr>().map_err(|error| {
            ServerError::Config(format!(
                "NESTED_BIND_ADDR 无法解析为地址（{bind_raw}）：{error}"
            ))
        })?;

        let max_body_bytes = match std::env::var("NESTED_MAX_BODY_BYTES") {
            Ok(raw) => raw.parse::<usize>().map_err(|error| {
                ServerError::Config(format!(
                    "NESTED_MAX_BODY_BYTES 无法解析为数字（{raw}）：{error}"
                ))
            })?,
            Err(_) => Self::DEFAULT_MAX_BODY_BYTES,
        };

        let database_url = std::env::var("DATABASE_URL")
            .ok()
            .filter(|value| !value.is_empty());

        Ok(Self {
            bind_addr,
            database_url,
            shutdown_timeout: Duration::from_secs(10),
            max_body_bytes,
        })
    }

    /// 是否配置了数据库。
    #[must_use]
    pub const fn has_database(&self) -> bool {
        self.database_url.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_bind_parses() {
        assert!(Config::DEFAULT_BIND.parse::<SocketAddr>().is_ok());
    }

    #[test]
    fn from_env_works_without_variables() {
        // 注意：不修改进程环境，避免测试间互相干扰（Rust 测试并行运行）。
        let config = Config::from_env().expect("默认配置必须可用");
        assert!(config.shutdown_timeout.as_secs() > 0);
        assert!(config.max_body_bytes > 0);
    }

    #[test]
    fn database_presence_is_reported() {
        let config = Config {
            bind_addr: Config::DEFAULT_BIND.parse().expect("valid"),
            database_url: None,
            shutdown_timeout: Duration::from_secs(1),
            max_body_bytes: 1024,
        };
        assert!(!config.has_database());
    }
}
