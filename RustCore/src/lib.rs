//! # RustCore — DeepSeek Chat Rust 核心（Tier 2 骨架）
//!
//! 集成形态：staticlib + 最小 C ABI（ADR-0004 方案 A）。Swift 侧通过
//! `Sources/CRustCore/include/rustcore.h` 声明的函数与本 crate 交互，
//! 复杂数据一律 JSON 出入，C 头不随业务字段演进。
//!
//! 模块边界：
//! - [`json`]：极简 JSON（零依赖，离线可构建）
//! - [`eval`]：T0 计算器（`dc_eval_expr` 的求值核心）
//! - [`index`]：最小索引核心（Tier 3 替换为 embedding + 向量索引）
//! - [`ffi`]：C ABI 层（unsafe 全部收敛在此）

pub mod eval;
pub mod index;
pub mod json;

mod ffi;

pub use ffi::*;
