//! # nested_app —— Flutter ↔ Rust 桥接层
//!
//! 由 `flutter_rust_bridge` 生成的绑定把 [`api`] 模块里的函数暴露给 Dart。
//! Flutter 只与本 crate 对话（铁律 A1/A3/T4）。
//!
//! ## 这个 crate 里的三部分
//!
//! | 文件 | 归属 | 说明 |
//! |---|---|---|
//! | `src/api/*.rs` | **手写（入库）** | 导出的业务 API，是唯一的跨语言契约面 |
//! | `src/frb_generated.rs` | 生成（不入库） | codegen 产出的桥接样板 |
//! | `lib/src/rust/**` | 生成（不入库） | codegen 产出的 Dart 绑定 |
//!
//! 生成物不入库的理由：它们完全由 `flutter_rust_bridge.yaml` 与 `src/api/` 决定，
//! 提交它们只会制造无意义的 diff 与合并冲突。重建命令：
//!
//! ```text
//! cd client/apps/flutter
//! flutter_rust_bridge_codegen generate
//! ```
//!
//! ## 前提：编译前必须先生成绑定
//!
//! 生成物不入库 ⇒ **刚 clone 的仓库里没有 `src/frb_generated.rs`**。
//! 由于下面是无条件声明 `mod frb_generated;`，任何 cargo 命令（fmt / clippy / test）
//! 在没有跑过 codegen 的机器上都会以
//! `failed to resolve mod 'frb_generated'` **直接失败**。
//!
//! 这是**刻意保留**的行为，而不是缺陷：
//!
//! - CI 在质量门禁之前先执行 codegen（见 `.github/workflows/ci.yml` 的
//!   `生成 FFI 绑定` 步骤），因此 CI 上永远是带着真实绑定做检查；
//! - 本地若忘记生成，得到的是一个**明确的**错误信息与修复命令，
//!   而不是"悄悄用了旧绑定"或"悄悄跳过了 FFI 层"。
//!
//! 只有一种情况例外：只改 `src/api/` 之外、与 FFI 无关的 crate 时可以直接构建，
//! 因为那时根本不依赖本 crate。
//!
//! ## 为什么这里没有 `#![forbid(unsafe_code)]`
//!
//! 生成代码里包含 FFI 必需的 `unsafe` 块（跨语言指针转换）。因此本项目对
//! **手写代码**用两条更强的约束替代它：
//!
//! - `nested-rules` 的 R1 规则扫描手写源码，禁止 panic 类调用与调试宏；
//! - `nested-rules` 的 A-ISOLATION 规则保证 FFI 层不会越界依赖服务端。
//!
//! 换言之：不用 crate 级 `forbid` 一刀切，是因为它会把**生成代码**一起拦下，
//! 而真正需要约束的是手写的 `src/api/`。
//!
//! ## 契约要求（铁律 A3 / A4）
//!
//! - 只暴露**业务语义**函数，不暴露 `execute_sql` 之类的实现细节；
//! - 跨边界只传可序列化的简单结构，不传裸指针、不传数据库句柄；
//! - 所有函数**禁止** panic：错误一律以结构化结果返回（铁律 E1）。

// 生成代码的 lint 豁免（理由见下）。
//
// 为什么豁免整个 crate 而不是逐个 `#[allow]`：
//   `frb_generated.rs` 由 codegen 每次重新生成，在其中插入 `#[allow]` 会被覆盖；
//   而它的代码风格不受我们控制（例如 `self as _` 转换、`use super::*` 通配导入、
//   不需要的 `else` 分支等）。因此这类噪音必须在**模块之外**压制。
//
// 这不等于放过 FFI 层：手写的 `src/api/` 仍受 `nested-rules` 的 R1 规则
// （禁止 panic 类调用）与 A-ISOLATION 规则约束。
//
// `unreachable_pub` 也一并豁免：生成代码在**二进制/库 root** 上写 `pub use io::*;`，
// 该 lint 会把它判为无效可见性。
#![allow(unsafe_code, unreachable_pub, clippy::all, clippy::pedantic)]

// `mod frb_generated;` 由 codegen 自动注入并**必须保持为第一个 item**：
// 生成文件顶部带有 `#![allow(...)]` 内部属性，而 Rust 只允许内部属性出现在
// 文件/模块的最前面。手工把它移到别处会导致编译失败。
mod frb_generated;

pub mod api;
