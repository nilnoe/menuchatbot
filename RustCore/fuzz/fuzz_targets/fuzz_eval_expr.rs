//! fuzz 目标：`dc_eval_expr` 的输入边界（表达式文本）。
//!
//! 直接把 `eval` / `json` 源码按路径引入（staticlib 无法被 fuzz 链接），
//! 与 crate 内实现保持同源。CI cron job 运行 ≥ 10 万迭代（AU-16）。

#![no_main]

#[path = "../../src/eval.rs"]
mod eval;
#[path = "../../src/json.rs"]
mod json;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(text) = std::str::from_utf8(data) {
        let _ = eval::evaluate(text);
    }
});
