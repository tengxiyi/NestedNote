# 技术债登记表

> 依据《工程铁律》V8：**禁止**用隐藏的 `TODO` 代替登记。
> 所有临时方案、已知妥协、待偿还的简化实现都必须在这里有一条记录。
>
> 字段说明：**影响**（不还债会发生什么）｜**触发条件**（什么情况下必须马上处理）｜**预计偿还**（阶段/时间）。

| # | 位置 | 债务描述 | 影响 | 触发条件 | 预计偿还 | 状态 |
|---|---|---|---|---|---|---|
| 1 | `client/tools/nested-rules/src/checks.rs` | clippy 的 `expect_used`/`unwrap_used` 在 workspace lint 里被设为 `allow`，而非 `deny` + 定向豁免。原因是 Clippy **不允许**在带 `#[test]` 的条目上写 `#[allow]`（会报 useless attribute），导致测试代码无法逐处压制。当前靠 `nested-rules` 的 R1 规则（只扫 `src/` 且跳过 `#[cfg(test)]`）兜底。 | 若有人绕过 `just check-rules` 只跑 clippy，产品代码里的 `expect()` 不会被拦住；两道门禁的保护强度不一致。 | 出现"漏过 R1 的 panic 导致线上崩溃"，或 Clippy 支持测试定向豁免时 | P1 | 登记 |
| 2 | `client/apps/flutter/pubspec.yaml` | `description` 与依赖版本在上游变化较快（Flutter 3.47.6 / Dart 3.13.5 已核实），但 `pubspec.lock` 尚未生成（需 Flutter 工具链）。 | 在 `pubspec.lock` 入库前，不同机器的 `pub get` 可能解析出不同的次要版本，违反铁律 B1（构建可复现）。 | Flutter 工具链接入后**立即**执行 `flutter pub get` 并提交 lock 文件 | P0 收尾 | 待处理 |

## 登记规范

1. 发现债务 → 立即开一条记录，不要等到"以后统一整理"。
2. 每条债务必须在对应代码处留一行引用注释，格式：`// TECH-DEBT(#12): 见 docs/tech-debt.md`
3. 每次阶段 Gate 评审时逐条过一遍：偿还、延期（写新日期）、或升级为正式任务。
4. **禁止**无限延期：同一债务延期 3 次以上必须排入当前阶段。
