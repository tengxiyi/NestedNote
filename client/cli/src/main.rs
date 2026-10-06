//! # nested-cli —— 拾光笔记内核命令行
//!
//! ## 为什么第一阶段先做 CLI 而不是 UI
//!
//! 开发计划 P1 的验收标准是"**在没有任何 Flutter 代码的前提下**，用 CLI 完成
//! 完整生命周期"。好处是：
//!
//! - 数据内核的正确性可以在没有 UI 干扰的情况下被证明；
//! - 压测与崩溃注入可以在命令行里自动化（铁律 Z5/Z6）；
//! - 未来排查用户现场问题时，可以让用户跑 `nested doctor` 拿到结构化诊断。
//!
//! ## 用法
//!
//! ```text
//! nested version                     版本与品牌信息
//! nested doctor  [--data-dir DIR]    就绪自检 + 完整性校验
//! nested init    [--data-dir DIR]    初始化数据目录与数据库
//! nested seed    [--data-dir DIR] [--notes N]   生成测试数据（占位：P1 完成）
//! ```
//!
//! 说明：本文件在 P0 阶段只实现 `version` / `doctor` / `init`，
//! 其余子命令以明确的 `NotImplemented` 错误退出——**禁止**用假成功掩盖未实现功能
//! （铁律 E6：失败必须可见）。

// CLI 是**唯一**允许直接读写标准输出的地方：它的产物就是给人看的文本。
// 其余 crate 一律禁止 println!/eprintln!（日志走 tracing，铁律 E4）。
#![allow(clippy::print_stdout, clippy::print_stderr)]
#![forbid(unsafe_code)]

use std::path::PathBuf;
use std::process::ExitCode;

use nested_core::{NestedCore, branding};

/// 默认数据目录名（用户主目录下）。
const DEFAULT_DATA_DIR_NAME: &str = "NestedNote";

/// 退出码。
mod exit_code {
    /// 成功。
    pub(crate) const OK: u8 = 0;
    /// 用法错误。
    pub(crate) const USAGE: u8 = 2;
    /// 运行时失败（含未实现）。
    pub(crate) const FAILURE: u8 = 1;
}

fn main() -> ExitCode {
    init_tracing();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map_or("help", String::as_str);

    let result = match command {
        "version" | "--version" | "-V" => run_version(),
        "doctor" => run_doctor(&args[1..]),
        "init" => run_init(&args[1..]),
        "seed" | "search" | "import" | "export" | "backup" | "restore" | "reindex" | "bench" => {
            run_planned(command)
        }
        "help" | "--help" | "-h" => run_help(),
        other => {
            eprintln!("未知子命令：{other}");
            eprintln!("运行 `nested help` 查看可用命令。");
            return ExitCode::from(exit_code::USAGE);
        }
    };

    match result {
        Ok(()) => ExitCode::from(exit_code::OK),
        Err(()) => ExitCode::from(exit_code::FAILURE),
    }
}

/// 初始化日志（默认 INFO，可用 `NESTED_LOG` 覆盖；铁律 E4）。
fn init_tracing() {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_env("NESTED_LOG").unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .try_init();
}

/// `nested version`
fn run_version() -> Result<(), ()> {
    println!("{}", branding::version_string());
    println!("中文名   ：{}", branding::BRAND_NAME_ZH);
    println!("英文名   ：{}", branding::BRAND_NAME_EN);
    println!("工程标识 ：{}", branding::ENGINEERING_ID);
    println!("数据库   ：{}", branding::DATABASE_FILE);
    println!("协议版本 ：{}", protocol::PROTOCOL_VERSION);
    Ok(())
}

/// `nested help`
fn run_help() -> Result<(), ()> {
    println!("{} —— 内核命令行工具", branding::BRAND_NAME_EN);
    println!();
    println!("用法：nested <命令> [选项]");
    println!();
    println!("命令：");
    println!("  version                     显示品牌与版本信息");
    println!("  doctor  [--data-dir DIR]    就绪自检 + 数据库完整性校验");
    println!("  init    [--data-dir DIR]    初始化数据目录与数据库（执行迁移）");
    println!("  help                        显示本帮助");
    println!();
    println!("以下命令属于 P1 阶段，尚未实现（会以明确错误退出）：");
    println!("  seed / search / import / export / backup / restore / reindex / bench");
    println!();
    println!("选项：");
    println!("  --data-dir DIR    指定数据目录，默认 {DEFAULT_DATA_DIR_NAME}（位于用户主目录）");
    println!();
    println!("环境变量：");
    println!("  NESTED_HOME       数据目录（与 --data-dir 等价，命令行优先）");
    println!("  NESTED_LOG        日志级别，例如 info / debug / nested_db=trace");
    Ok(())
}

/// `nested doctor`
fn run_doctor(rest: &[String]) -> Result<(), ()> {
    let data_dir = resolve_data_dir(rest)?;
    println!("数据目录：{}", data_dir.display());

    let core = match NestedCore::open(&data_dir) {
        Ok(core) => core,
        Err(error) => {
            eprintln!("无法打开内核：{}（错误码 {}）", error, error.code());
            eprintln!("建议：{}", error.user_hint());
            return Err(());
        }
    };

    let mut all_ok = true;
    for (name, ok) in core.readiness() {
        let mark = if ok { "OK  " } else { "FAIL" };
        println!("  [{mark}] {name}");
        all_ok &= ok;
    }

    match core.schema_version() {
        Ok(version) => println!("  schema 版本：{version}"),
        Err(error) => {
            eprintln!("无法读取 schema 版本：{error}");
            all_ok = false;
        }
    }
    match core.note_count() {
        Ok(count) => println!("  笔记数量：{count}"),
        Err(error) => {
            eprintln!("无法统计笔记：{error}");
            all_ok = false;
        }
    }
    match core.pending_sync_count() {
        Ok(count) => println!("  待同步操作：{count}"),
        Err(error) => {
            eprintln!("无法统计待同步操作：{error}");
            all_ok = false;
        }
    }

    if all_ok {
        println!("结论：一切正常。");
        Ok(())
    } else {
        eprintln!("结论：存在问题，请查看上方 FAIL 项。");
        Err(())
    }
}

/// `nested init`
fn run_init(rest: &[String]) -> Result<(), ()> {
    let data_dir = resolve_data_dir(rest)?;
    let core = match NestedCore::open(&data_dir) {
        Ok(core) => core,
        Err(error) => {
            eprintln!("初始化失败：{}（错误码 {}）", error, error.code());
            eprintln!("建议：{}", error.user_hint());
            return Err(());
        }
    };
    println!("已初始化：{}", data_dir.display());
    match core.schema_version() {
        Ok(version) => println!("schema 版本：{version}"),
        Err(error) => {
            eprintln!("但无法读取 schema 版本：{error}");
            return Err(());
        }
    }
    Ok(())
}

/// P1 阶段命令的显式占位。
///
/// 刻意返回失败而不是"打印一行假装成功"：未实现的功能必须让调用方看见
/// （铁律 E6）。
fn run_planned(command: &str) -> Result<(), ()> {
    eprintln!("子命令 `{command}` 尚未实现（计划阶段：P1，见 docs/01-开发计划.md）。");
    eprintln!("P0 阶段可用的命令：version / doctor / init / help");
    Err(())
}

/// 解析 `--data-dir` / `NESTED_HOME` / 默认值。
fn resolve_data_dir(args: &[String]) -> Result<PathBuf, ()> {
    let mut explicit: Option<PathBuf> = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--data-dir" => {
                index += 1;
                if index >= args.len() {
                    eprintln!("--data-dir 需要一个目录参数");
                    return Err(());
                }
                explicit = Some(PathBuf::from(&args[index]));
            }
            other if other.starts_with("--data-dir=") => {
                explicit = Some(PathBuf::from(&other["--data-dir=".len()..]));
            }
            other => {
                eprintln!("无法识别的选项：{other}");
                return Err(());
            }
        }
        index += 1;
    }

    if let Some(dir) = explicit {
        return Ok(dir);
    }
    if let Ok(home) = std::env::var("NESTED_HOME")
        && !home.trim().is_empty()
    {
        return Ok(PathBuf::from(home));
    }
    let base = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .map_err(|_| {
            eprintln!("无法确定用户主目录，请用 --data-dir 或 NESTED_HOME 显式指定");
        })?;
    Ok(PathBuf::from(base).join(DEFAULT_DATA_DIR_NAME))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_data_dir_wins() {
        let args = vec!["--data-dir".to_owned(), "D:/tmp/nested".to_owned()];
        assert_eq!(
            resolve_data_dir(&args).expect("ok"),
            PathBuf::from("D:/tmp/nested")
        );
    }

    #[test]
    fn equals_form_is_accepted() {
        let args = vec!["--data-dir=D:/x".to_owned()];
        assert_eq!(resolve_data_dir(&args).expect("ok"), PathBuf::from("D:/x"));
    }

    #[test]
    fn missing_value_is_rejected() {
        let args = vec!["--data-dir".to_owned()];
        assert!(resolve_data_dir(&args).is_err());
    }

    #[test]
    fn unknown_option_is_rejected() {
        let args = vec!["--nope".to_owned()];
        assert!(resolve_data_dir(&args).is_err());
    }

    #[test]
    fn planned_commands_fail_loudly() {
        // 未实现的命令必须返回失败，而不是静默成功（铁律 E6）
        assert!(run_planned("seed").is_err());
    }
}
