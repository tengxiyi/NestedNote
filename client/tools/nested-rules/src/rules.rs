//! 规则注册表。

use std::path::Path;

use crate::checks;
use crate::report::Violation;

/// 一条可机械检查的规则。
#[derive(Debug)]
pub struct Rule {
    /// 铁律编号（与 `docs/02-工程铁律.md` 一致）。
    pub id: &'static str,
    /// 显示标题。
    pub title: &'static str,
    /// 检查函数。
    pub run: fn(&Path) -> Vec<Violation>,
}

/// 全部规则。
///
/// 顺序即输出顺序：先查最严重的（数据安全、隔离），再查风格类问题。
pub const ALL: &[Rule] = &[
    Rule {
        id: "R1",
        title: "R1: 产品代码禁止 panic 类调用（unwrap/expect/panic!/todo!）",
        run: checks::panic_free_production_code,
    },
    Rule {
        id: "D2",
        title: "D2: 禁止裸 DELETE（必须软删除）",
        run: checks::no_raw_delete,
    },
    Rule {
        id: "Q4",
        title: "Q4: 禁止用字符串插值构造 SQL",
        run: checks::no_interpolated_sql,
    },
    Rule {
        id: "A-ISOLATION",
        title: "A: 客户端与服务端 workspace 隔离",
        run: checks::workspace_isolation,
    },
    Rule {
        id: "S3",
        title: "S3: 禁止硬编码凭据",
        run: checks::no_hardcoded_secrets,
    },
    Rule {
        id: "B1",
        title: "B1: 工具链与依赖锁定文件齐备",
        run: checks::required_files_present,
    },
    Rule {
        id: "V6",
        title: "V6: 禁止大文件入库",
        run: checks::no_large_files,
    },
    Rule {
        id: "B-ENCODING",
        title: "B-ENCODING: PowerShell 脚本含中文时必须有 UTF-8 BOM",
        run: checks::powershell_scripts_need_bom,
    },
];
