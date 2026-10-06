# Gate P0 评审记录 —— 工程基座

- **评审日期**：P0 收尾（Flutter 工具链接入后）
- **结论**：**通过**
- **上一阶段**：无（项目起点）
- **下一阶段**：P1 Rust Core 数据内核

---

## 1. 入口条件

项目从零开始，无前置 Gate。入口时仓库中只有一份技术文档。

## 2. 交付物核对（对照《开发计划》§1）

| 计划项 | 状态 | 证据 |
|---|---|---|
| P0-1 Monorepo 目录结构 | ✅ | `client/`、`server/` 两个独立 workspace + `shared/protocol` |
| P0-2 Rust workspace 初始化 | ✅ | 客户端 11 个 crate + 服务端 6 个 crate 均可编译 |
| P0-3 `rust-toolchain.toml` 固定版本 | ✅ | 两端各自锁定 1.92.0 |
| P0-4 Flutter 工程初始化（四平台） | ✅ | `flutter create` 生成 windows/macos/ios/android（114 个文件） |
| P0-5 **flutter_rust_bridge 打通最小闭环** | ✅ | 见 §3，真实应用启动后由 Rust 建库并返回自检结果 |
| P0-6 统一任务入口（justfile） | ✅ | `justfile`，含 check / test / build / cli / infra 等任务 |
| P0-7 CI 三作业 | ✅ | `.github/workflows/ci.yml`：变更检测 + 铁律检查 + 行尾规范 + 双端作业 + 依赖审计 |
| P0-8 ADR 机制 | ✅ | `docs/adr/0001`–`0005` |
| P0-9 开发环境文档 | ✅ | README「快速开始」+ `.env.example` |

### 如何验证（可复制命令）

```powershell
# 1) 两端全量门禁
cd client; cargo fmt --all -- --check; cargo clippy --workspace --all-targets -- -D warnings; cargo test --workspace
cd ../server; cargo fmt --all -- --check; cargo clippy --workspace --all-targets -- -D warnings; cargo test --workspace

# 2) 铁律检查
cd ../client; cargo run -p nested-rules -- --root ..

# 3) CLI 内核验收（无 UI）
cargo run -p nested-cli -- doctor --data-dir C:\tmp\nested-demo

# 4) Flutter 侧（需 Flutter 3.47.6）
cd ../apps/flutter
cargo build -p nested_app --release          # 供 flutter test 加载
$env:FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR = "<repo>\client\target\release"
flutter analyze; flutter test

# 5) 真实应用（GUI）
flutter build windows --debug
.\build\windows\x64\runner\Debug\nested.exe  # 启动后由 Rust 建库
```

## 3. P0-5 实测证据（本阶段的核心验收）

真实应用（`nested.exe`）启动后，Dart 调 Rust 取回的自检结果
（由应用写入 `%TEMP%\engine-status.txt`，属于临时诊断手段，见技术债 #3）：

```text
dataDir=C:\Users\tomas\AppData\Roaming\app.nestednote\nested
ready=true
displayName=拾光笔记
version=0.1.0
protocolVersion=1
databasePath=C:\Users\tomas\AppData\Roaming\app.nestednote\nested\nested.db
message=null
check database_open=true
check schema_current=true
check integrity=true
```

交叉验证：用 CLI 打开**同一个**数据库，确认它是有效的库而非空文件。

```text
[OK] database_open   [OK] schema_current   [OK] integrity
schema 版本：1   笔记数量：0   待同步操作：0
结论：一切正常。
```

这一条同时证明了四件事：
1. Rust 动态库被正确编译、打包进应用并被 Dart 加载；
2. FFI 双向序列化（含中文品牌名）正确；
3. SQLite 建库与迁移体系在真实应用中可用；
4. 数据库文件落在平台约定的位置，且可被其他工具（CLI）独立打开。

## 4. 质量门禁结果

| 门禁 | 结果 |
|---|---|
| `cargo fmt --check`（客户端 / 服务端） | ✅ 通过 |
| `cargo clippy --all-targets -- -D warnings`（两端） | ✅ 0 警告 |
| `cargo test --workspace`（客户端） | ✅ **149** 个用例通过 |
| `cargo test --workspace`（服务端） | ✅ **22** 个用例通过 |
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 3 个用例通过（含 1 个真实 FFI 集成测试） |
| `nested-rules` 铁律检查 | ✅ 0 违规（7 条规则自动化） |
| 迁移文件哈希护栏 | ✅ 通过（含 LF 校验） |
| 行尾规范 | ✅ 通过 |
| `cargo audit` | ⚠️ **未执行**（本机未安装 cargo-audit）；CI 中已配置，见 §6 |

## 5. 关键决策与偏差

| 事项 | 决策 | 记录位置 |
|---|---|---|
| 客户端与服务端拆成两个 workspace | 采纳 | [ADR 0002](../adr/0002-split-client-server-workspaces.md) |
| 迁移文件哈希护栏 | 采纳 | [ADR 0003](../adr/0003-migration-hash-guard.md) |
| 铁律检查器用 Rust 而非 PowerShell | 采纳 | [ADR 0004](../adr/0004-rules-checker-in-rust.md) |
| 服务端不锁定 musl 目标、用 Debian 基础镜像 | 采纳 | [ADR 0005](../adr/0005-server-target-and-base-image.md) |
| 数据目录改为"交给平台约定" | **偏离原章程** | 章程 §1.4 已更新并说明原因（`path_provider` 返回值比手拼品牌名更符合平台习惯） |
| clippy 的 `unwrap_used`/`expect_used` 不阻断 | **偏离铁律 R1 的字面要求** | 铁律附 A 已说明：测试代码无法逐处 `#[allow]`，改由 `nested-rules` 的 R1 只对产品代码强制 |
| FFI crate（`nested_app`）整体豁免 unsafe/clippy | **偏离铁律 R2 的字面要求** | 见 `apps/rust/src/lib.rs` 顶部说明：生成代码含 FFI 必需的 `unsafe`，手写部分仍受 R1/A-ISOLATION 约束 |

## 6. 未完成项与豁免

| 项 | 现状 | 处理 |
|---|---|---|
| `cargo audit` 未在本地跑过 | 本机无 `cargo-audit`；CI 已配置该作业 | 不阻塞 P0；下次 CI 运行即为验证 |
| CI 尚未在 GitHub 上真实跑过 | 仓库为本地 git，未推送远端 | 不阻塞 P0；推送后需观察首个流水线结果 |
| macOS / iOS / Android 未构建验证 | 本机无 macOS 与移动签名环境 | 明确属 P5 范围；Windows 接线已修好并记录命名坑（技术债 #5） |
| 覆盖率未度量（铁律 Z1 要求核心 crate ≥ 80%） | 未安装 `cargo-llvm-cov` | **P1 必须补齐**，见 §8 |
| 性能与内存指标未度量 | 数据量仅为 0 条笔记 | 属 P4 范围 |

## 7. 风险复查

| 风险 | 状态 |
|---|---|
| R1 flutter_rust_bridge 四端踩坑 | **部分兑现并已缓解**：Windows 上踩到"crate 名连字符 vs cargo 规范化下划线"导致 dll 未打包；已通过统一命名为 `nested_app` 解决，并写入技术债 #5 提醒其他平台 |
| R3 自研富文本编辑器失控 | 未触发（P3 才涉及） |
| R5 SQLx 编译期校验依赖 CI 数据库 | 已规避：使用离线模式（未启用 `query!` 宏），服务端测试为纯内存测试 |
| R9 范围蔓延 | 未触发 |
| 新增：Flutter 生成物与手写文件互相覆盖 | 已发现并建立流程（备份 → `flutter create` → 恢复）；写入 README |
| 新增：PowerShell 5.1 编码陷阱 | 已解决（scripts/*.ps1 统一加 UTF-8 BOM），写入 ADR 0004 |

## 8. 结论与 P1 的入口条件

**结论：通过。** P0 的目标"任意一台干净环境按 README 操作能在 30 分钟内得到可运行窗口，
窗口内显示从 Rust 取回的版本号"已达成（本机实测：构建约 40 秒，运行后可看到自检结果）。

进入 P1 前必须完成的事项：

1. **安装 `cargo-llvm-cov` 并建立覆盖率基线**（铁律 Z1：核心 crate ≥ 80%）；
2. **安装 `cargo-audit` 并跑一次本地审计**；
3. 把仓库推送到远端，观察首个 CI 流水线是否全绿（当前 CI 只验证过本地等价命令）；
4. 在 P1 开工前完成第一批详细设计文档（`docs/design/06-Document-Model设计.md`、
   `05-SQLite数据库设计.md`、`04-Rust-Core架构设计.md`）——铁律 M1 要求先设计后编码。

P1 的第一件事：按开发计划 §2 实现 FTS5 全文搜索（含中文分词方案对比基准）、
附件内容寻址落盘（含原子写与哈希校验）、导入导出与备份（含 round-trip 测试）。
