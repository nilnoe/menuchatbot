//! fuzz 目标：`dc_index_upsert` 的输入边界（消息 JSON 文本）。
//!
//! 同 `fuzz_eval_expr`：路径引入 `json` 解析器，与 crate 内实现同源。

#![no_main]

#[path = "../../src/json.rs"]
mod json;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(text) = std::str::from_utf8(data) {
        let _ = json::parse(text);
    }
});
