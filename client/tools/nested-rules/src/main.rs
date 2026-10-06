//! 铁律检查器命令行入口。
//!
//! 用法：
//!
//! ```text
//! nested-rules [--root DIR] [--report-only] [--quiet]
//! ```
//!
//! 退出码：0 = 通过；1 = 有违规；2 = 用法错误。
//!
//! CI 与 `just check-rules` 使用本命令；`scripts/check-rules.ps1` 仅保留作本地快速自检。

#![forbid(unsafe_code)]
// 命令行入口：报告走 stdout、用法错误走 stderr，均为刻意行为。
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::path::PathBuf;
use std::process::ExitCode;

use nested_rules::{Options, find_repo_root, run};

fn main() -> ExitCode {
    let mut root: Option<PathBuf> = None;
    let mut report_only = false;
    let mut quiet = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => {
                if let Some(value) = args.next() {
                    root = Some(PathBuf::from(value));
                } else {
                    eprintln!("--root 需要一个目录参数");
                    return ExitCode::from(2);
                }
            }
            "--report-only" => report_only = true,
            "--quiet" => quiet = true,
            "--help" | "-h" => {
                print_help();
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("无法识别的选项：{other}");
                print_help();
                return ExitCode::from(2);
            }
        }
    }

    let Some(root) = root.or_else(find_repo_root) else {
        eprintln!("找不到仓库根目录（需同时包含 client 与 server），请用 --root 显式指定");
        return ExitCode::from(2);
    };

    let options = Options {
        root,
        verbose: !quiet,
    };
    let report = run(&options);

    if quiet {
        println!("{}", report.summary_line());
    } else {
        report.print();
    }

    if report.is_clean() || report_only {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn print_help() {
    println!("nested-rules —— 铁律自动检查器");
    println!();
    println!("用法：nested-rules [选项]");
    println!();
    println!("选项：");
    println!("  --root DIR      指定仓库根目录（默认从当前目录向上查找）");
    println!("  --report-only   只报告，不以失败退出（用于本地排查）");
    println!("  --quiet         只输出一行结论（供脚本消费）");
    println!("  -h, --help      显示本帮助");
}
