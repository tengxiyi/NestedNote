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
| `nested-rules` 铁律检查 | ✅ 0 违规（8 条规则自动化） |
| 迁移文件哈希护栏 | ✅ 通过（含 LF 校验） |
| 行尾规范 | ✅ 通过 |
| **测试覆盖率（铁律 Z1）** | ✅ **已建立并纳入 CI**，见 §4.1 |
| `cargo audit` —— 客户端 | ✅ 0 漏洞 |
| `cargo audit` —— 服务端 | ✅ 0 漏洞（含 1 项**带理由的豁免**，见下） |

### 4.1 覆盖率基线（铁律 Z1）

门禁脚本：`scripts/coverage-gate.ps1`（CI 的 client 作业已接入）。
数字来自 `cargo llvm-cov`，**只对已有实质实现的 crate 卡 80%**——理由见下。

| 计入门禁的 crate | 行覆盖率 | 用例数 |
|---|---:|---:|
| nested-model | 95.9% | 39 |
| nested-db | 94.4% | 72 |
| nested-core | 93.9% | 16 |
| nested-attachment | 94.9% | 21 |
| nested-sync | 100% | 3 |
| nested-rules | 88.7% | 39 |
| **客户端合计** | — | **204** |

**不计入门禁的项及原因**（每一项都在 CI 输出中打印出来，避免"看不见"）：

| 项 | 现状 | 原因 / 解除条件 |
|---|---|---|
| nested-import / nested-export | 0%（仅类型与常量） | 尚无实现；覆盖率对"未实现的代码"没有意义。**P1 实现后必须并入 `$gate`** |
| nested-search / nested-crypto | 无可执行代码 | 仅接口与 trait；P1 实现 FTS5 / ADR 决定加密方案后并入 |
| nested-cli | 27.6% | 进程级二进制（`std::process::exit`）；要测需先把 `main` 重构为库，收益不抵成本 |
| FFI（nested_app） | 96.3% | 已排除 codegen 生成的 `frb_generated.rs`（不入库、覆盖率恒为 0） |

> **为什么不一刀切**：如果对全部 crate 卡 80%，占位 crate 会因为"可执行代码只有几行"
> 而轻松达标，形成自欺的指标。因此门禁清单是**显式列出**的，且每新增一个实现
> 就必须同步加入清单——这一点写在脚本头部注释里。

> **关于依赖审计**：客户端 78 项、服务端 241 项锁定的依赖均未发现可利用漏洞。
> 服务端豁免了 **RUSTSEC-2023-0071**（`rsa` 时序侧信道），理由与复核条件写在
> `server/.cargo/audit.toml`：该 crate 只被 `sqlx-mysql` 引用，而本项目只用 PostgreSQL，
> `cargo tree -i rsa` 证明它**不在实际编译的依赖树中**；上游当前无补丁（`patched = []`）。
> 为防豁免退化成"眼不见为净"，CI 中已加一步检查：一旦 `rsa` 出现在依赖树里就失败。

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
| ~~CI 尚未在 GitHub 上真实跑过~~ | ✅ **已跑通**：<https://github.com/tengxiyi/NestedNote/actions> 全部 7 个作业通过 | 关闭。前两次失败的原因已修复并记录（见 CHANGELOG：生成物不入库导致 cargo 无法解析模块；CI 缺 Flutter 工具链导致 codegen 失败） |
| macOS / iOS / Android 未构建验证 | 本机无 macOS 与移动签名环境 | 明确属 P5 范围；Windows 接线已修好并记录命名坑（技术债 #5） |
| ~~覆盖率未度量~~ | ✅ **已度量并纳入 CI**，见 §4.1 | 关闭 |
| 性能与内存指标未度量 | 数据量仅为 0 条笔记 | 属 P4 范围 |
| 依赖审计的"是否被 yank"检查 | 本机网络下多次超时（不影响漏洞判定结论） | 属环境问题；CI 侧该作业已通过 |
| **P1 开工前的设计文档** | ✅ 三份已补齐（`docs/design/04` / `05` / `06`，共约 3100 行） | 关闭。撰写过程中发现 20 项缺陷与不一致，已全部登记到 `docs/tech-debt.md`（#8–#20） |

## 6.1 设计文档撰写中发现的问题（本轮最有价值的产出）

三份设计文档要求"逐行核对源码"，因此顺带把实现审了一遍。发现的问题**全部登记**在
`docs/tech-debt.md`，其中值得立即知道的是：

| 严重度 | 问题 | 位置 |
|---|---|---|
| 高 | **死锁陷阱**：持有 `Database::connection()` 的 guard 时再调用任何 `Database` 方法会自己等自己（测试中真实挂死过一次） | 技术债 #8 |
| 高 | `sync_operations` 注释称"任何本地写都入队"，实际只有 `save_with_document` 入队 → P6 会出现"部分变更同步不出去" | 技术债 #12 |
| 高 | 事务行为不统一：`with_transaction` 用 `Immediate`，两个业务写入口用 `Deferred` | 技术债 #10 |
| 中 | FTS5 索引内容重复（`searchable_text` 把列表项收集两遍）——**已修复并加回归测试** | 技术债 #9 |
| 中 | 软删标签后无法再建同名标签（唯一索引不含 `deleted_at_ms`，且无复活逻辑） | 技术债 #13 |
| 中 | `save_note` 无条件 `touch()` 且 `parent_revision_id` 恒为 `None` | 技术债 #11 |
| 中 | `CoreError::Conflict` 混淆"重名"与"并发冲突"，且把确定性失败标为可重试 | 技术债 #14 |
| 中 | 附件插入主路径不完整：`ContentStore`（写文件）与 `attachments::upsert`（写库）之间没有函数串起来 | 技术债 #17 |
| 低 | `readiness()` 每次都在首屏跑全库 `integrity_check` | 技术债 #16 |
| 低 | `MAX_PAGE_SIZE` 只覆盖笔记列表，附件/标签/同步队列无 clamps | 技术债 #18 |

> 这些不是"文档工作"的副产品，而是**先设计后编码**（铁律 M1）本该带来的收益：
> 把实现写清楚的过程，就是发现自己没想清楚的地方的过程。

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

1. ~~安装 `cargo-llvm-cov` 并建立覆盖率基线~~ ✅ **已完成**（见 §4.1，且已接入 CI）；
2. ~~完成第一批详细设计文档~~ ✅ **已完成**（`docs/design/04` / `05` / `06`）；
3. 处理 §6.1 中标记为"高"的三项技术债（#8 死锁陷阱、#12 同步入队缺口、#10 事务行为不统一）——
   它们都在 P1 的写入路径上，越晚处理代价越大。

P1 的第一件事：按开发计划 §2 实现 FTS5 全文搜索（含中文分词方案对比基准）、
附件内容寻址落盘（含原子写与哈希校验）、导入导出与备份（含 round-trip 测试）。

P1 的第一件事：按开发计划 §2 实现 FTS5 全文搜索（含中文分词方案对比基准）、
附件内容寻址落盘（含原子写与哈希校验）、导入导出与备份（含 round-trip 测试）。
