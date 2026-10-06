//! # server-core —— 服务端基础设施
//!
//! 配置、结构化错误、日志初始化。**不**包含业务逻辑，**不**接触客户端 crate
//! （技术文档 §4.2 硬约束 3）。

#![forbid(unsafe_code)]

pub mod config;
pub mod error;
pub mod telemetry;

pub use config::Config;
pub use error::{ApiError, ServerError};
