//! 日志与可观测性初始化。
//!
//! **铁律 S3**：日志默认脱敏。禁止记录密码、token、密钥、笔记正文、附件内容。
//! 本模块只负责格式化与过滤器，**不**提供任何"顺手把请求体打出来"的开关。

use tracing_subscriber::EnvFilter;

/// 初始化结构化日志。
///
/// 环境变量 `NESTED_LOG` 控制级别（如 `info`、`debug`、`server_api=trace`）；
/// 默认 `info`（技术文档 §32：Release 默认 INFO）。
///
/// 返回 `false` 表示全局订阅者已存在（例如测试中重复调用），不视为错误。
pub fn init_tracing() -> bool {
    let filter = EnvFilter::try_from_env("NESTED_LOG").unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .with_ansi(false)
        .try_init()
        .is_ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn init_is_idempotent_and_never_panics() {
        // 重复初始化不应 panic（返回 false 即可），因为测试与嵌入场景会多次调用
        let _ = super::init_tracing();
        let _ = super::init_tracing();
    }
}
