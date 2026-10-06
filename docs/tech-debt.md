# 技术债登记表

> 依据《工程铁律》V8：**禁止**用隐藏的 `TODO` 代替登记。
> 所有临时方案、已知妥协、待偿还的简化实现都必须在这里有一条记录。
>
> 字段说明：**影响**（不还债会发生什么）｜**触发条件**（什么情况下必须马上处理）｜**预计偿还**（阶段/时间）。

| # | 位置 | 债务描述 | 影响 | 触发条件 | 预计偿还 | 状态 |
|---|---|---|---|---|---|---|
| 1 | `client/tools/nested-rules/src/checks.rs` | clippy 的 `expect_used`/`unwrap_used` 在 workspace lint 里被设为 `allow`，而非 `deny` + 定向豁免。原因是 Clippy **不允许**在带 `#[test]` 的条目上写 `#[allow]`（会报 useless attribute），导致测试代码无法逐处压制。当前靠 `nested-rules` 的 R1 规则（只扫 `src/` 且跳过 `#[cfg(test)]`）兜底。 | 若有人绕过 `just check-rules` 只跑 clippy，产品代码里的 `expect()` 不会被拦住；两道门禁的保护强度不一致。 | 出现"漏过 R1 的 panic 导致线上崩溃"，或 Clippy 支持测试定向豁免时 | P1 | 登记 |
| 2 | `client/apps/flutter/pubspec.yaml` | `description` 与依赖版本在上游变化较快（Flutter 3.47.6 / Dart 3.13.5 已核实），但 `pubspec.lock` 尚未生成（需 Flutter 工具链）。 | 在 `pubspec.lock` 入库前，不同机器的 `pub get` 可能解析出不同的次要版本，违反铁律 B1（构建可复现）。 | Flutter 工具链接入后**立即**执行 `flutter pub get` 并提交 lock 文件 | P0 收尾 | ✅ 已偿还（pubspec.lock 已入库） |
| 3 | `client/apps/flutter/lib/core/engine_providers.dart` | 自检结果被额外写入 `%TEMP%/engine-status.txt` 作为临时诊断手段。 | 界面只显示一句可读提示，排查"动态库没加载 / 目录不可写"需要看真实返回值；但这份文件是未托管的临时产物，不是正式日志。 | 结构化日志（tracing → 文件）落地时 | P1 | 登记 |
| 4 | `client/apps/flutter/analysis_options.yaml` | `rust_builder/**` 整体排除在分析器范围外，其中 cargokit 是第三方 vendored 代码（实测有 74 个报错）。 | 排除范围偏大：若将来往 `rust_builder/` 添加自己的 Dart 代码，它不会被分析。 | 需要修改 rust_builder 的 Dart 代码时，改为只排除 `rust_builder/cargokit/**` | P2 | 登记 |
| 5 | `client/apps/flutter/rust_builder/` | Cargokit 是按"从零集成"模板生成的（`flutter_rust_bridge_codegen integrate`），其中 Windows/macOS/Linux/Android/iOS 五个平台的接线**只实测了 Windows**。 | 其他平台可能在首次构建时才暴露类似的命名/路径问题（Windows 上就踩到了 `nested-app` vs `nested_app` 导致 dll 未打包）。 | P5 移动端阶段、以及在 macOS 上首次构建时 | P5 | 登记 |
| 6 | `server/.cargo/audit.toml` | 豁免 RUSTSEC-2023-0071（`rsa` 时序侧信道）。依据：该 crate 只被 `sqlx-mysql` 引用，而本项目只用 PostgreSQL，`cargo tree -i rsa` 证明它不在编译树中；上游当前**无补丁**（`patched = []`）。 | 若将来引入 MySQL 后端，该豁免会立刻变成真实风险；且豁免长期存在会掩盖"上游已修复"的事实，导致错过升级。 | 任一条件满足即重评：引入 MySQL 后端 / sqlx 去掉 mysql 可选依赖 / `rsa` 发布修复版本 / 直接使用 `rsa` | 每次依赖升级时复核 | 登记（已加 CI 前提检查） |
| 7 | `docs/reports/gate-p0.md` | Gate P0 记录中 `cargo audit` 一栏曾标注"未执行"。现已在本地实测：客户端 0 漏洞、服务端 0 漏洞（含 1 项带理由的豁免）。 | 文档与实测状态不一致会误导后续评审。 | — | 已在本条目登记，下次 Gate 评审时更新记录 | ✅ 已偿还 |

## 登记规范

1. 发现债务 → 立即开一条记录，不要等到"以后统一整理"。
2. 每条债务必须在对应代码处留一行引用注释，格式：`// TECH-DEBT(#12): 见 docs/tech-debt.md`
3. 每次阶段 Gate 评审时逐条过一遍：偿还、延期（写新日期）、或升级为正式任务。
4. **禁止**无限延期：同一债务延期 3 次以上必须排入当前阶段。
