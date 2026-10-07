// SPDX-License-Identifier: AGPL-3.0-or-later
//! 复制时的名称处理。
//!
//! ## 为什么"加后缀"不能天真地拼字符串
//!
//! 名称有**字符数上限**（笔记标题 [`MAX_TITLE_CHARS`]、笔记本名
//! [`MAX_NOTEBOOK_NAME_CHARS`]）。若原名称已经接近上限，直接拼「（副本）」
//! 会超限，`Note::new` / `Notebook::new` 会返回校验错误——
//! 用户看到的是"复制失败"，而原因（标题太长）与他做的事毫无关系。
//!
//! 因此这里**先截断再拼后缀**，并且后缀必须完整保留：
//! 它是用户辨认"这是副本"的唯一线索，被截掉就等于复制出一堆同名笔记。

use nested_model::{MAX_NOTEBOOK_NAME_CHARS, MAX_TITLE_CHARS, ModelError, Result};

/// 复制出来的名称后缀。
///
/// 用中文全角括号而不是 ` (copy)`：前者是中文界面里的常规写法，
/// 也不容易被误认为标题原有的一部分。
pub const COPY_SUFFIX: &str = "（副本）";

/// 为**笔记副本**生成标题（上限 [`MAX_TITLE_CHARS`]）。
///
/// # Errors
///
/// 见 [`copy_name`]。
pub fn copy_title(original: &str) -> Result<String> {
    copy_name(original, MAX_TITLE_CHARS)
}

/// 为**笔记本副本**生成名称（上限 [`MAX_NOTEBOOK_NAME_CHARS`]）。
///
/// 两个公开入口而不是让调用方各自传上限：上限值与实体绑定，
/// 让调用方手写数字迟早会有人写错（写错的表现是"复制失败"，
/// 而报错信息指向校验，不指向这里）。
///
/// # Errors
///
/// 见 [`copy_name`]。
pub fn copy_notebook_name(original: &str) -> Result<String> {
    copy_name(original, MAX_NOTEBOOK_NAME_CHARS)
}

/// 在**不超长的前提下**给名称加上 [`COPY_SUFFIX`]。
///
/// ## 截断按"字符"而不是"字节"
///
/// `MAX_*_CHARS` 是字符数，而中文一个字在 UTF-8 里占 3 字节。
/// 按字节截断会把一个汉字劈成两半，产生非法 UTF-8——Rust 的 `String`
/// 不允许那种状态，因此按字节切会在运行时 panic。
/// 这里用 `chars()` 计数并收集，天然按字符边界切分。
///
/// # Errors
///
/// 上限小于后缀长度时返回 [`ModelError::Validation`]。
/// 这是**配置错误**（有人把常量改小了），不是用户输入问题——
/// 因此宁可返回错误也不静默产出一个必然超限的字符串、让它在别处炸开。
pub fn copy_name(original: &str, max_chars: usize) -> Result<String> {
    if COPY_SUFFIX.chars().count() >= max_chars {
        return Err(ModelError::Validation {
            field: "copy.name",
            reason: "名称上限不大于副本后缀长度，任何副本都会超限",
        });
    }

    // 已经有后缀时**替换**而不是再追加。
    //
    // 否则复制一个副本会得到"报告（副本）（副本）"，每复制一次长一截。
    // 而"复制笔记本"会连里面的副本一起复制，这个叠加立刻就会发生——
    // 本项目实现后第一次端到端验证就看到了
    // `[验证S2]原件（副本）（副本）`。
    let base = original.strip_suffix(COPY_SUFFIX).unwrap_or(original);
    let budget = max_chars - COPY_SUFFIX.chars().count();
    let truncated: String = base.chars().take(budget).collect();
    Ok(format!("{truncated}{COPY_SUFFIX}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_name_gets_the_suffix() {
        assert_eq!(copy_title("工作").expect("ok"), "工作（副本）");
    }

    #[test]
    fn copying_a_copy_replaces_the_suffix_instead_of_stacking_it() {
        // 复制笔记本会连里面的副本一起复制，叠加立刻就会发生。
        // 端到端验证时看到过「原件（副本）（副本）」。
        let once = copy_title("报告").expect("ok");
        assert_eq!(once, "报告（副本）");
        let twice = copy_title(&once).expect("ok");
        assert_eq!(twice, "报告（副本）", "第二次复制不该再加一层后缀");
        let thrice = copy_title(&twice).expect("ok");
        assert_eq!(thrice, "报告（副本）");
    }

    #[test]
    fn a_name_that_merely_ends_with_the_suffix_text_is_not_mangled_twice() {
        // 只替换**一个**后缀：即便原名里恰好含"（副本）"，也只当它一个后缀
        let name = "报告（副本）说明（副本）";
        // 末尾那个被替换掉，中间那个保留（它是名称的一部分）
        assert_eq!(copy_title(name).expect("ok"), "报告（副本）说明（副本）");
    }

    #[test]
    fn result_never_exceeds_the_limit() {
        // 核心性质：无论原名多长，结果都必须在限内。
        // 否则调用方的 `Note::new` 会以一个与用户操作无关的理由失败。
        for limit in [10_usize, 20, 64, 256, 512] {
            let long = "很".repeat(limit * 2);
            let result = copy_name(&long, limit).expect("ok");
            assert!(
                result.chars().count() <= limit,
                "上限 {limit} 时结果长度 {} 超限",
                result.chars().count()
            );
            assert!(result.ends_with(COPY_SUFFIX), "后缀必须完整保留");
        }
    }

    #[test]
    fn exactly_at_the_limit_still_works() {
        let name = "字".repeat(MAX_TITLE_CHARS);
        let result = copy_title(&name).expect("ok");
        assert!(result.chars().count() <= MAX_TITLE_CHARS);
        assert!(result.ends_with(COPY_SUFFIX));
    }

    #[test]
    fn notebook_name_respects_its_own_smaller_limit() {
        // 笔记本名的上限（256）比笔记标题（512）小，因此用满标题长度
        // 去当笔记本名会超限——这正是"两个入口分开"要防的错。
        let name = "字".repeat(MAX_TITLE_CHARS);
        let result = copy_notebook_name(&name).expect("ok");
        assert!(
            result.chars().count() <= MAX_NOTEBOOK_NAME_CHARS,
            "笔记本副本名必须满足笔记本的上限"
        );
    }

    #[test]
    fn empty_name_gets_only_the_suffix() {
        // 笔记标题允许为空（未命名笔记）。副本的名称就是后缀本身，
        // 而不是空串——空标题在列表里无法辨认。
        assert_eq!(copy_title("").expect("ok"), COPY_SUFFIX);
    }

    #[test]
    fn chinese_text_is_not_split_mid_character() {
        // 若实现按字节截断，这里会因为切坏一个汉字而出问题。
        let name = "测试".repeat(MAX_NOTEBOOK_NAME_CHARS);
        let result = copy_notebook_name(&name).expect("ok");
        assert!(result.is_char_boundary(0));
        assert!(result.chars().count() <= MAX_NOTEBOOK_NAME_CHARS);
    }

    #[test]
    fn suffix_longer_than_limit_is_rejected_not_panicking() {
        assert!(copy_name("x", 2).is_err());
    }
}
