//! C ABI 层：Swift 侧唯一可见的入口。
//!
//! 原则（ADR-0004 / DESIGN_RUST_CORE §4）：
//! - 所有 `unsafe` 收敛在本模块；FFI 参数先校验再解引用；
//! - 可控错误一律转错误码（0=OK，负数=错误），杜绝跨 FFI unwind；
//! - release profile `panic = "abort"`，panic 不跨边界；
//! - 复杂数据一律 JSON 出入，C 头不随业务字段演进；
//! - 输出 JSON 由 Rust 分配，Swift 侧必须调用 `dc_free` 成对释放。
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use crate::audit;
use crate::engine::MockEmbedder;
use crate::eval;
use crate::index::{is_library_namespace, IndexCore, INDEX_VERSION};
use crate::json::{self, Json};
use crate::library::{ScanOptions, DEFAULT_EXTENSIONS};
use std::ffi::{c_char, c_void, CStr, CString};
use std::os::raw::c_int;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, RwLock};

// MARK: - 错误码（与 rustcore.h 保持一致，勿单边改动）

pub const DC_OK: c_int = 0;
pub const DC_ERR_INVALID_ARGUMENT: c_int = -1;
pub const DC_ERR_JSON: c_int = -2;
pub const DC_ERR_NOT_FOUND: c_int = -3;
pub const DC_ERR_UNAVAILABLE: c_int = -4;
pub const DC_ERR_INTERNAL: c_int = -5;
pub const DC_ERR_CANCELLED: c_int = -6;

/// 不透明索引句柄（Swift 只见指针；内部为 RwLock 支持只读并发检索）。
#[repr(C)]
pub struct dc_index {
    inner: RwLock<IndexCore>,
    /// 操作级取消标志（Tier 3）：长任务开始前清零、任务内轮询；
    /// 只影响当前长操作，不再像 Tier 2 闩锁那样永久禁用搜索 / 写入。
    cancel_requested: AtomicBool,
    last_error: Mutex<String>,
    /// 索引落盘目录（open 时传入；None = 纯内存，不持久化）。
    index_dir: Option<PathBuf>,
}

type FreeCallback = Option<unsafe extern "C" fn(*mut c_void)>;

// MARK: - 内部辅助

unsafe fn cstr<'a>(ptr: *const c_char) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("null pointer".to_string());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map_err(|_| "invalid UTF-8".to_string())
}

unsafe fn write_out(s: &str, out: *mut *mut c_char) -> Result<(), String> {
    if out.is_null() {
        return Err("null out pointer".to_string());
    }
    let c = CString::new(s).map_err(|_| "output contains NUL byte".to_string())?;
    *out = c.into_raw();
    audit::record_allocated();
    Ok(())
}

unsafe fn index_ref<'a>(ix: *mut dc_index) -> Result<&'a dc_index, String> {
    if ix.is_null() {
        Err("null index handle".to_string())
    } else {
        Ok(&*ix)
    }
}

fn set_error(ix: &dc_index, msg: &str) {
    *ix.last_error.lock().unwrap_or_else(|e| e.into_inner()) = msg.to_string();
}

fn last_error_string(ix: &dc_index) -> String {
    ix.last_error
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

fn is_cancelled(ix: &dc_index) -> bool {
    ix.cancel_requested.load(Ordering::SeqCst)
}

/// 把内部错误映射为错误码（按消息前缀归类，避免脆弱的位置耦合）。
fn error_code_for(msg: &str) -> c_int {
    if msg.contains("not found") {
        DC_ERR_NOT_FOUND
    } else if msg.starts_with("cancelled") {
        DC_ERR_CANCELLED
    } else if msg.starts_with("invalid ") && msg.contains("JSON") {
        DC_ERR_JSON
    } else {
        DC_ERR_INVALID_ARGUMENT
    }
}

fn result_to_code(ix: *mut dc_index, result: Result<(), String>) -> c_int {
    let code = match result {
        Ok(()) => DC_OK,
        Err(msg) => {
            if !ix.is_null() {
                set_error(unsafe { &*ix }, &msg);
            }
            error_code_for(&msg)
        }
    };
    audit::record_error(code);
    code
}

/// 解析 config JSON；非法 JSON 或版本不匹配返回 None（open 失败路径，
/// Swift 侧据此进入 `.unavailable` 降级）。
fn parse_config(config_json: *const c_char) -> Option<(String, i32)> {
    if config_json.is_null() {
        return Some(("history".to_string(), INDEX_VERSION));
    }
    let text = unsafe { cstr(config_json) }.ok()?;
    let value = json::parse(text).ok()?;
    let version = value
        .get("version")
        .and_then(Json::as_i64)
        .unwrap_or(INDEX_VERSION as i64);
    if version != INDEX_VERSION as i64 {
        return None;
    }
    let namespace = value
        .get("namespace")
        .and_then(Json::as_str)
        .unwrap_or("history")
        .to_string();
    Some((namespace, INDEX_VERSION))
}

// MARK: - 句柄生命周期

/// 打开索引：`path` 为索引落盘目录（可 NULL = 纯内存），`config_json`
/// 携带 namespace / 版本。版本不匹配或非法 JSON 返回 NULL，Swift 侧进入
/// `.unavailable` 降级；落盘文件版本过期时忽略文件（首次索引重建）。
#[no_mangle]
pub extern "C" fn dc_index_open(path: *const c_char, config_json: *const c_char) -> *mut dc_index {
    audit::record_call();
    let Some((namespace, _)) = parse_config(config_json) else {
        return std::ptr::null_mut();
    };
    let index_dir = if path.is_null() {
        None
    } else {
        unsafe { cstr(path) }.ok().map(PathBuf::from)
    };
    let mut core = IndexCore::new(namespace);
    if let Some(dir) = &index_dir {
        if let Ok(Some(stored)) = IndexCore::load(dir, INDEX_VERSION) {
            core.restore(stored);
        }
    }
    let handle = dc_index {
        inner: RwLock::new(core),
        cancel_requested: AtomicBool::new(false),
        last_error: Mutex::new(String::new()),
        index_dir,
    };
    audit::record_allocated();
    Box::into_raw(Box::new(handle))
}

#[no_mangle]
pub extern "C" fn dc_index_close(ix: *mut dc_index) {
    audit::record_call();
    if !ix.is_null() {
        // 落盘持久化（best-effort：保存失败不阻塞关闭）。
        if let Some(dir) = &unsafe { &*ix }.index_dir {
            let _ = unsafe { &*ix }
                .inner
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .save(dir);
        }
        audit::record_freed();
        unsafe {
            drop(Box::from_raw(ix));
        }
    }
}

// MARK: - 索引操作

/// 写入 / 更新一条文档：`message_json = {"id": "...", "content": "...", "namespace"?: "..."}`。
#[no_mangle]
pub extern "C" fn dc_index_upsert(ix: *mut dc_index, message_json: *const c_char) -> c_int {
    audit::record_call();
    let result = (|| -> Result<(), String> {
        let handle = unsafe { index_ref(ix) }?;
        let input = unsafe { cstr(message_json) }?;
        let value = json::parse(input).map_err(|e| format!("invalid message JSON: {}", e))?;
        let id = value
            .get("id")
            .and_then(Json::as_str)
            .ok_or("invalid message JSON: missing string 'id'")?
            .to_string();
        let content = value
            .get("content")
            .and_then(Json::as_str)
            .ok_or("invalid message JSON: missing string 'content'")?
            .to_string();
        let namespace = value
            .get("namespace")
            .and_then(Json::as_str)
            .map(str::to_string);
        handle
            .inner
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .upsert(id, content, namespace);
        Ok(())
    })();
    result_to_code(ix, result)
}

#[no_mangle]
pub extern "C" fn dc_index_delete(ix: *mut dc_index, message_id: *const c_char) -> c_int {
    audit::record_call();
    let result = (|| -> Result<(), String> {
        let handle = unsafe { index_ref(ix) }?;
        let id = unsafe { cstr(message_id) }?;
        handle
            .inner
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .delete(id)
    })();
    result_to_code(ix, result)
}

/// 检索：`query` 为关键词文本，`options_json = {"limit"?: N, "namespace"?: "..."}`。
/// 成功时 `out_json` 为 `{"hits": [{"id","score","content"}], "count": N}`。
#[no_mangle]
pub extern "C" fn dc_index_search(
    ix: *mut dc_index,
    query: *const c_char,
    options_json: *const c_char,
    out_json: *mut *mut c_char,
    _free: FreeCallback,
) -> c_int {
    audit::record_call();
    let result = (|| -> Result<String, String> {
        let handle = unsafe { index_ref(ix) }?;
        let query_text = unsafe { cstr(query) }?.to_string();
        let (limit, namespace) = parse_options(options_json)?;
        let core = handle.inner.read().unwrap_or_else(|e| e.into_inner());
        let hits = core.search(
            &query_text,
            limit,
            namespace.as_deref(),
            Some(&MockEmbedder::default()),
        );
        let hits_json: Vec<Json> = hits
            .iter()
            .map(|hit| {
                Json::object(vec![
                    ("id", Json::String(hit.id.clone())),
                    ("score", Json::Number(crate::json::Number::Int(hit.score))),
                    ("content", Json::String(hit.content.clone())),
                    ("path", Json::String(hit.path.clone())),
                ])
            })
            .collect();
        Ok(Json::object(vec![
            ("hits", Json::Array(hits_json)),
            (
                "count",
                Json::Number(crate::json::Number::Int(hits.len() as i64)),
            ),
        ])
        .to_string())
    })();
    let code = match result {
        Ok(payload) => match unsafe { write_out(&payload, out_json) } {
            Ok(()) => DC_OK,
            Err(_) => DC_ERR_INVALID_ARGUMENT,
        },
        Err(msg) => {
            if !ix.is_null() {
                set_error(unsafe { &*ix }, &msg);
            }
            error_code_for(&msg)
        }
    };
    audit::record_error(code);
    code
}

fn parse_options(options_json: *const c_char) -> Result<(usize, Option<String>), String> {
    if options_json.is_null() {
        return Ok((10, None));
    }
    let text = unsafe { cstr(options_json) }?;
    let value = json::parse(text).map_err(|e| format!("invalid options JSON: {}", e))?;
    let limit = value
        .get("limit")
        .and_then(Json::as_i64)
        .unwrap_or(10)
        .clamp(1, 100) as usize;
    let namespace = value
        .get("namespace")
        .and_then(Json::as_str)
        .map(str::to_string);
    Ok((limit, namespace))
}

/// 重建：清空后从 `source_path` 指向的 JSON 数组快照重灌；`source_path` 为
/// NULL 时仅清空。快照元素形如 `{"id","content","namespace"?}`。
#[no_mangle]
pub extern "C" fn dc_index_rebuild(ix: *mut dc_index, source_path: *const c_char) -> c_int {
    audit::record_call();
    let result = (|| -> Result<(), String> {
        let handle = unsafe { index_ref(ix) }?;
        // 操作级取消：开始前清零。
        handle.cancel_requested.store(false, Ordering::SeqCst);
        let mut core = handle.inner.write().unwrap_or_else(|e| e.into_inner());
        core.clear();
        if !source_path.is_null() {
            let path = unsafe { cstr(source_path) }?.to_string();
            let snapshot = std::fs::read_to_string(&path)
                .map_err(|e| format!("cannot read snapshot: {}", e))?;
            let value =
                json::parse(&snapshot).map_err(|e| format!("invalid snapshot JSON: {}", e))?;
            let Json::Array(docs) = value else {
                return Err("invalid snapshot JSON: expected array".to_string());
            };
            for doc in docs {
                if is_cancelled(handle) {
                    return Err("cancelled".to_string());
                }
                let id = doc
                    .get("id")
                    .and_then(Json::as_str)
                    .ok_or("invalid snapshot: missing string 'id'")?
                    .to_string();
                let content = doc
                    .get("content")
                    .and_then(Json::as_str)
                    .ok_or("invalid snapshot: missing string 'content'")?
                    .to_string();
                let namespace = doc
                    .get("namespace")
                    .and_then(Json::as_str)
                    .map(str::to_string);
                core.upsert(id, content, namespace);
            }
        }
        Ok(())
    })();
    result_to_code(ix, result)
}

/// 资料库增量索引：扫描 `root_path` → 分块 → mock embedding → 增量更新
/// （mtime + contentHash 未变不重 embed）。`options_json` 形如
/// `{"corpus_id","corpus_name","extensions":[...],"max_file_bytes","chunk_tokens","overlap_tokens"}`。
/// 成功时 `out_json` 为 `{"corpus_id","corpus_name","files_scanned","files_indexed",
/// "files_skipped","files_removed","chunks_added","chunks_total","duration_ms"}`。
#[no_mangle]
pub extern "C" fn dc_index_index_corpus(
    ix: *mut dc_index,
    root_path: *const c_char,
    options_json: *const c_char,
    out_json: *mut *mut c_char,
    _free: FreeCallback,
) -> c_int {
    audit::record_call();
    let result = (|| -> Result<String, String> {
        let handle = unsafe { index_ref(ix) }?;
        // 操作级取消：开始前清零，长任务内轮询（Tier 3 按操作 token）。
        handle.cancel_requested.store(false, Ordering::SeqCst);
        let root = unsafe { cstr(root_path) }?.to_string();
        let (corpus_id, corpus_name, options) = parse_corpus_options(options_json)?;

        let embedder = MockEmbedder::default();
        let is_cancelled = || is_cancelled(handle);
        let report = {
            let mut core = handle.inner.write().unwrap_or_else(|e| e.into_inner());
            core.index_library(
                std::path::Path::new(&root),
                &options,
                &embedder,
                &is_cancelled,
            )?
        };
        // 落盘（含取消后的部分进度，重启可续跑；best-effort）。
        if let Some(dir) = &handle.index_dir {
            let core = handle.inner.read().unwrap_or_else(|e| e.into_inner());
            core.save(dir)?;
        }
        Ok(Json::object(vec![
            ("corpus_id", Json::String(corpus_id)),
            ("corpus_name", Json::String(corpus_name)),
            (
                "files_scanned",
                Json::Number(crate::json::Number::Int(report.files_scanned as i64)),
            ),
            (
                "files_indexed",
                Json::Number(crate::json::Number::Int(report.files_indexed as i64)),
            ),
            (
                "files_skipped",
                Json::Number(crate::json::Number::Int(report.files_skipped as i64)),
            ),
            (
                "files_removed",
                Json::Number(crate::json::Number::Int(report.files_removed as i64)),
            ),
            (
                "chunks_added",
                Json::Number(crate::json::Number::Int(report.chunks_added as i64)),
            ),
            (
                "chunks_total",
                Json::Number(crate::json::Number::Int(report.chunks_total as i64)),
            ),
            (
                "duration_ms",
                Json::Number(crate::json::Number::Int(report.duration_ms as i64)),
            ),
        ])
        .to_string())
    })();
    let code = match result {
        Ok(payload) => match unsafe { write_out(&payload, out_json) } {
            Ok(()) => DC_OK,
            Err(_) => DC_ERR_INVALID_ARGUMENT,
        },
        Err(msg) => {
            if !ix.is_null() {
                set_error(unsafe { &*ix }, &msg);
            }
            error_code_for(&msg)
        }
    };
    audit::record_error(code);
    code
}

/// 解析资料库索引 options；全部字段可选（默认见 [`ScanOptions::default`]）。
fn parse_corpus_options(
    options_json: *const c_char,
) -> Result<(String, String, ScanOptions), String> {
    let mut options = ScanOptions::default();
    let mut corpus_id = String::new();
    let mut corpus_name = String::new();
    if !options_json.is_null() {
        let text = unsafe { cstr(options_json) }?;
        let value = json::parse(text).map_err(|e| format!("invalid options JSON: {}", e))?;
        corpus_id = value
            .get("corpus_id")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_string();
        corpus_name = value
            .get("corpus_name")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_string();
        if let Some(Json::Array(extensions)) = value.get("extensions") {
            let parsed: Vec<String> = extensions
                .iter()
                .filter_map(Json::as_str)
                .map(|s| s.to_lowercase())
                .collect();
            if !parsed.is_empty() {
                options.extensions = parsed;
            }
        }
        if let Some(max) = value.get("max_file_bytes").and_then(Json::as_i64) {
            options.max_file_bytes = max.max(1) as u64;
        }
        if let Some(chunk) = value.get("chunk_tokens").and_then(Json::as_i64) {
            options.chunk_tokens = chunk.max(64) as usize;
        }
        if let Some(overlap) = value.get("overlap_tokens").and_then(Json::as_i64) {
            options.overlap_tokens = overlap.max(0) as usize;
        }
    }
    if options.extensions.is_empty() {
        options.extensions = DEFAULT_EXTENSIONS.iter().map(|s| s.to_string()).collect();
    }
    Ok((corpus_id, corpus_name, options))
}

#[no_mangle]
pub extern "C" fn dc_index_status(ix: *mut dc_index, out_json: *mut *mut c_char) -> c_int {
    audit::record_call();
    let result = (|| -> Result<String, String> {
        let handle = unsafe { index_ref(ix) }?;
        let core = handle.inner.read().unwrap_or_else(|e| e.into_inner());
        let is_library = is_library_namespace(core.namespace());
        Ok(Json::object(vec![
            (
                "version",
                Json::Number(crate::json::Number::Int(INDEX_VERSION as i64)),
            ),
            (
                "document_count",
                Json::Number(crate::json::Number::Int(core.document_count() as i64)),
            ),
            ("namespace", Json::String(core.namespace().to_string())),
            ("ready", Json::Bool(true)),
            (
                "files",
                Json::Number(crate::json::Number::Int(if is_library {
                    core.manifest_len() as i64
                } else {
                    0
                })),
            ),
            (
                "indexed_at",
                Json::Number(crate::json::Number::Int(core.indexed_at())),
            ),
        ])
        .to_string())
    })();
    let code = match result {
        Ok(payload) => match unsafe { write_out(&payload, out_json) } {
            Ok(()) => DC_OK,
            Err(_) => DC_ERR_INVALID_ARGUMENT,
        },
        Err(msg) => {
            if !ix.is_null() {
                set_error(unsafe { &*ix }, &msg);
            }
            error_code_for(&msg)
        }
    };
    audit::record_error(code);
    code
}

#[no_mangle]
pub extern "C" fn dc_index_cancel(ix: *mut dc_index) {
    audit::record_call();
    if !ix.is_null() {
        unsafe { &*ix }
            .cancel_requested
            .store(true, Ordering::SeqCst);
    }
}

#[no_mangle]
pub extern "C" fn dc_index_last_error(ix: *mut dc_index, buf: *mut c_char, len: usize) -> c_int {
    audit::record_call();
    if ix.is_null() || buf.is_null() || len == 0 {
        return 0;
    }
    let msg = last_error_string(unsafe { &*ix });
    let bytes = msg.as_bytes();
    let n = bytes.len().min(len - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    n as c_int
}

// MARK: - T0 计算器

/// 表达式求值：`expr_json = {"expr": "1 + 2*3"}`。
/// 成功输出 `{"ok": true, "value": 7}`；任何失败都输出
/// `{"ok": false, "error": "..."}` 并返回负错误码（不 panic）。
#[no_mangle]
pub extern "C" fn dc_eval_expr(
    expr_json: *const c_char,
    out_json: *mut *mut c_char,
    _free: FreeCallback,
) -> c_int {
    audit::record_call();
    let result = (|| -> Result<(c_int, String), String> {
        let input = unsafe { cstr(expr_json) }?;
        let value = json::parse(input).map_err(|e| format!("invalid expr JSON: {}", e))?;
        let expr = value
            .get("expr")
            .and_then(Json::as_str)
            .ok_or("expr JSON missing string 'expr'")?
            .to_string();
        match eval::evaluate(&expr) {
            Ok(number) => Ok((
                DC_OK,
                Json::object(vec![
                    ("ok", Json::Bool(true)),
                    ("value", Json::Number(number)),
                ])
                .to_string(),
            )),
            Err(message) => Ok((
                DC_ERR_INVALID_ARGUMENT,
                Json::object(vec![
                    ("ok", Json::Bool(false)),
                    ("error", Json::String(message)),
                ])
                .to_string(),
            )),
        }
    })();

    let code = match result {
        Ok((code, payload)) => match unsafe { write_out(&payload, out_json) } {
            Ok(()) => code,
            Err(_) => DC_ERR_INVALID_ARGUMENT,
        },
        Err(msg) => {
            let payload = Json::object(vec![
                ("ok", Json::Bool(false)),
                ("error", Json::String(msg)),
            ])
            .to_string();
            match unsafe { write_out(&payload, out_json) } {
                Ok(()) => DC_ERR_JSON,
                Err(_) => DC_ERR_INVALID_ARGUMENT,
            }
        }
    };
    audit::record_error(code);
    code
}

/// 释放本 crate 分配的输出 JSON。调用方必须成对使用；
/// 不可用于释放其他来源的指针（所有权规则见 DESIGN_RUST_CORE §4.3）。
#[no_mangle]
pub extern "C" fn dc_free(ptr: *mut c_void) {
    audit::record_call();
    if !ptr.is_null() {
        audit::record_freed();
        unsafe {
            drop(CString::from_raw(ptr as *mut c_char));
        }
    }
}

// MARK: - 审计与可观测性（ADR-0009 P2）

/// 一次性安装 panic hook 并设置崩溃日志路径（可传 NULL = 不落文件）。
#[no_mangle]
pub extern "C" fn dc_audit_init(log_path: *const c_char) {
    audit::record_call();
    let path = if log_path.is_null() {
        None
    } else {
        unsafe { cstr(log_path) }.ok().map(str::to_string)
    };
    audit::set_crash_log_path(path);
    audit::install_panic_hook();
}

/// 导出审计快照：`out_json = {"version","total_calls","outstanding_allocations",
/// "panic_count","error_counts","recent_panics"}`，由调用方 `dc_free` 释放。
#[no_mangle]
pub extern "C" fn dc_audit_snapshot(out_json: *mut *mut c_char) -> c_int {
    audit::record_call();
    let payload = audit::snapshot().to_string();
    let code = match unsafe { write_out(&payload, out_json) } {
        Ok(()) => DC_OK,
        Err(_) => DC_ERR_INVALID_ARGUMENT,
    };
    audit::record_error(code);
    code
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::Mutex as StdMutex;

    /// 串行化产生错误码的测试：`audit` 是进程级计数器，AU-13 需要精确增量，
    /// 并行执行会串扰（-1 码可能来自其他测试）。
    static AUDIT_SERIAL: StdMutex<()> = StdMutex::new(());

    /// 封装：把输出 JSON 拷回 String 并释放。
    fn take_output(out: *mut *mut c_char) -> Option<String> {
        let ptr = unsafe { *out };
        if ptr.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        dc_free(ptr.cast());
        Some(s)
    }

    fn eval_ffi(expr: &str) -> (c_int, String) {
        let input = CString::new(expr).unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = dc_eval_expr(input.as_ptr(), &mut out, None);
        let output = take_output(&mut out).unwrap_or_default();
        (code, output)
    }

    #[test]
    fn eval_roundtrip() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let (code, output) = eval_ffi(r#"{"expr":"1 + 2 * 3"}"#);
        assert_eq!(code, DC_OK);
        let value = json::parse(&output).unwrap();
        assert_eq!(value.get("ok").unwrap().as_bool(), Some(true));
        assert_eq!(value.get("value").unwrap().as_i64(), Some(7));
    }

    #[test]
    fn eval_invalid_expression_returns_code_and_error_json() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let (code, output) = eval_ffi(r#"{"expr":"1/0"}"#);
        assert_eq!(code, DC_ERR_INVALID_ARGUMENT);
        let value = json::parse(&output).unwrap();
        assert_eq!(value.get("ok").unwrap().as_bool(), Some(false));
        assert!(value.get("error").unwrap().as_str().is_some());
    }

    #[test]
    fn eval_invalid_json_returns_json_error() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let (code, output) = eval_ffi("not json");
        assert_eq!(code, DC_ERR_JSON);
        assert!(json::parse(&output).unwrap().get("ok").unwrap().as_bool() == Some(false));
    }

    fn open_index(config: Option<&str>) -> *mut dc_index {
        let config = config.map(|s| CString::new(s).unwrap());
        dc_index_open(
            std::ptr::null(),
            config.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
        )
    }

    #[test]
    fn index_upsert_search_delete_roundtrip() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let ix = open_index(Some(r#"{"namespace":"history"}"#));
        assert!(!ix.is_null());

        let msg =
            CString::new(r#"{"id":"m1","content":"香蕉牛奶","namespace":"history"}"#).unwrap();
        assert_eq!(dc_index_upsert(ix, msg.as_ptr()), DC_OK);
        let msg = CString::new(r#"{"id":"m2","content":"苹果派"}"#).unwrap();
        assert_eq!(dc_index_upsert(ix, msg.as_ptr()), DC_OK);

        let query = CString::new("香蕉").unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = dc_index_search(ix, query.as_ptr(), std::ptr::null(), &mut out, None);
        assert_eq!(code, DC_OK);
        let output = take_output(&mut out).unwrap();
        let value = json::parse(&output).unwrap();
        assert_eq!(value.get("count").unwrap().as_i64(), Some(1));
        assert_eq!(
            value
                .get("hits")
                .unwrap()
                .at(0)
                .unwrap()
                .get("id")
                .unwrap()
                .as_str(),
            Some("m1")
        );

        let id = CString::new("m1").unwrap();
        assert_eq!(dc_index_delete(ix, id.as_ptr()), DC_OK);
        assert_eq!(
            dc_index_delete(ix, id.as_ptr()),
            DC_ERR_NOT_FOUND,
            "重复删除应返回 not found"
        );

        let mut status: *mut c_char = std::ptr::null_mut();
        assert_eq!(dc_index_status(ix, &mut status), DC_OK);
        let status_json = take_output(&mut status).unwrap();
        let status = json::parse(&status_json).unwrap();
        assert_eq!(status.get("document_count").unwrap().as_i64(), Some(1));

        dc_index_close(ix);
    }

    #[test]
    fn index_upsert_rejects_missing_fields() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let ix = open_index(None);
        let bad = CString::new(r#"{"id":"m1"}"#).unwrap();
        assert_eq!(dc_index_upsert(ix, bad.as_ptr()), DC_ERR_JSON);

        let mut buf = [0i8; 256];
        let n = dc_index_last_error(ix, buf.as_mut_ptr(), buf.len());
        assert!(n > 0);
        let msg = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy();
        assert!(
            msg.contains("content"),
            "last_error 应给出可读原因，实际: {}",
            msg
        );
        dc_index_close(ix);
    }

    #[test]
    fn index_open_rejects_invalid_config() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let ix = open_index(Some("not json"));
        assert!(ix.is_null(), "非法 config 应返回 NULL（open 失败）");
    }

    #[test]
    fn cancel_does_not_block_search_or_upsert() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        // Tier 3：取消是操作级标志，只影响长任务，不再闩锁禁用搜索 / 写入。
        let ix = open_index(None);
        let msg = CString::new(r#"{"id":"m1","content":"内容"}"#).unwrap();
        assert_eq!(dc_index_upsert(ix, msg.as_ptr()), DC_OK);
        dc_index_cancel(ix);

        let query = CString::new("内容").unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = dc_index_search(ix, query.as_ptr(), std::ptr::null(), &mut out, None);
        assert_eq!(code, DC_OK, "取消不应影响搜索");
        dc_index_close(ix);
    }

    // MARK: - Tier 3 资料库 FFI

    fn corpus_temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("dc_ffi_{}_{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn index_corpus(ix: *mut dc_index, root: &str, options: &str) -> (c_int, String) {
        let root = CString::new(root).unwrap();
        let options = CString::new(options).unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = dc_index_index_corpus(ix, root.as_ptr(), options.as_ptr(), &mut out, None);
        let output = take_output(&mut out).unwrap_or_default();
        (code, output)
    }

    #[test]
    fn index_corpus_roundtrip_and_incremental_ffi() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let dir = corpus_temp_dir("corpus");
        std::fs::write(dir.join("a.md"), "苹果种植指南：施肥与浇水").unwrap();
        std::fs::write(dir.join("b.txt"), "香蕉牛奶制作方法").unwrap();

        let ix = open_index(Some(r#"{"namespace":"library/c1"}"#));
        assert!(!ix.is_null());
        let (code, output) = index_corpus(
            ix,
            dir.to_str().unwrap(),
            r#"{"corpus_id":"c1","corpus_name":"资料库一"}"#,
        );
        assert_eq!(code, DC_OK, "索引应成功：{}", output);
        let value = json::parse(&output).unwrap();
        assert_eq!(value.get("files_indexed").unwrap().as_i64(), Some(2));
        assert_eq!(value.get("corpus_id").unwrap().as_str(), Some("c1"));

        let query = CString::new("香蕉").unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        assert_eq!(
            dc_index_search(
                ix,
                query.as_ptr(),
                CString::new(r#"{"limit":5,"namespace":"library/c1"}"#)
                    .unwrap()
                    .as_ptr(),
                &mut out,
                None
            ),
            DC_OK
        );
        let search = take_output(&mut out).unwrap();
        let search = json::parse(&search).unwrap();
        assert_eq!(search.get("count").unwrap().as_i64(), Some(1));
        let hit = search.get("hits").unwrap().at(0).unwrap();
        assert!(
            hit.get("path")
                .unwrap()
                .as_str()
                .unwrap()
                .ends_with("b.txt"),
            "命中应带来源路径"
        );

        // 增量：未变化 → 不重 embed。
        let (code2, output2) = index_corpus(
            ix,
            dir.to_str().unwrap(),
            r#"{"corpus_id":"c1","corpus_name":"资料库一"}"#,
        );
        assert_eq!(code2, DC_OK);
        let value2 = json::parse(&output2).unwrap();
        assert_eq!(value2.get("files_indexed").unwrap().as_i64(), Some(0));
        assert_eq!(value2.get("files_removed").unwrap().as_i64(), Some(0));

        // 状态应含资料库信息。
        let mut status: *mut c_char = std::ptr::null_mut();
        assert_eq!(dc_index_status(ix, &mut status), DC_OK);
        let status_json = take_output(&mut status).unwrap();
        let status = json::parse(&status_json).unwrap();
        assert_eq!(status.get("files").unwrap().as_i64(), Some(2));

        dc_index_close(ix);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn index_corpus_persists_across_reopen() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let corpus = corpus_temp_dir("persist_corpus");
        std::fs::write(corpus.join("a.md"), "苹果种植指南").unwrap();
        let index_dir = corpus_temp_dir("persist_index");

        let path = CString::new(index_dir.to_str().unwrap()).unwrap();
        let config = CString::new(r#"{"namespace":"library/c2","version":2}"#).unwrap();
        let ix = dc_index_open(path.as_ptr(), config.as_ptr());
        assert!(!ix.is_null());
        let (code, _) = index_corpus(
            ix,
            corpus.to_str().unwrap(),
            r#"{"corpus_id":"c2","corpus_name":"持久化"}"#,
        );
        assert_eq!(code, DC_OK);
        dc_index_close(ix);

        // 重开同目录：索引从磁盘恢复，无需重新索引即可检索。
        let ix2 = dc_index_open(path.as_ptr(), config.as_ptr());
        assert!(!ix2.is_null());
        let query = CString::new("苹果").unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        assert_eq!(
            dc_index_search(
                ix2,
                query.as_ptr(),
                CString::new(r#"{"limit":5,"namespace":"library/c2"}"#)
                    .unwrap()
                    .as_ptr(),
                &mut out,
                None
            ),
            DC_OK
        );
        let search = json::parse(&take_output(&mut out).unwrap()).unwrap();
        assert_eq!(search.get("count").unwrap().as_i64(), Some(1));
        dc_index_close(ix2);

        let _ = std::fs::remove_dir_all(&corpus);
        let _ = std::fs::remove_dir_all(&index_dir);
    }

    #[test]
    fn index_corpus_rejects_escape_and_missing_root() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let ix = open_index(Some(r#"{"namespace":"library/c3"}"#));
        assert!(!ix.is_null());
        // 根目录不存在。
        let (code, _) = index_corpus(ix, "/nonexistent/dc-root-xyz", r#"{"corpus_id":"c3"}"#);
        assert_eq!(code, DC_ERR_INVALID_ARGUMENT);
        // 空 root。
        assert_eq!(
            dc_index_index_corpus(
                ix,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                None
            ),
            DC_ERR_INVALID_ARGUMENT
        );
        dc_index_close(ix);
    }

    #[test]
    fn null_pointers_return_error_not_panic() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = dc_eval_expr(std::ptr::null(), &mut out, None);
        assert_eq!(code, DC_ERR_JSON, "null 输入应返回错误码而非 panic");
        assert_eq!(
            dc_index_upsert(std::ptr::null_mut(), std::ptr::null()),
            DC_ERR_INVALID_ARGUMENT
        );
    }

    // MARK: - 审计快照（AU-13 / AU-14）

    /// 解析当前快照的错误码计数（进程级计数器，测试用增量断言）。
    fn snapshot_counts() -> std::collections::HashMap<String, u64> {
        let snap = crate::audit::snapshot();
        let mut map = std::collections::HashMap::new();
        if let Some(crate::json::Json::Object(items)) = snap.get("error_counts") {
            for (key, value) in items {
                map.insert(key.clone(), value.as_i64().unwrap_or(0) as u64);
            }
        }
        map
    }

    #[test]
    fn audit_snapshot_counts_match_returned_codes_au13() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let before = snapshot_counts();

        let (code, _) = eval_ffi(r#"{"expr":"1/0"}"#);
        assert_eq!(code, DC_ERR_INVALID_ARGUMENT);
        let ix = open_index(None);
        assert_eq!(
            dc_index_upsert(ix, std::ptr::null()),
            DC_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            dc_index_delete(ix, std::ptr::null()),
            DC_ERR_INVALID_ARGUMENT
        );
        dc_index_close(ix);

        let after = snapshot_counts();
        let delta_minus1 =
            after.get("-1").copied().unwrap_or(0) - before.get("-1").copied().unwrap_or(0);
        assert_eq!(
            delta_minus1, 3,
            "AU-13：-1 错误码计数应与实际返回一致（单线程执行）"
        );
        assert_eq!(
            after.get("0").copied().unwrap_or(0),
            before.get("0").copied().unwrap_or(0),
            "AU-13：成功路径不记错误码"
        );
    }

    #[test]
    fn outstanding_allocations_return_to_zero_au14() {
        let _guard = AUDIT_SERIAL.lock().unwrap();
        let before = crate::audit::outstanding_allocations();

        for _ in 0..10 {
            let (code, _) = eval_ffi(r#"{"expr":"1 + 2"}"#);
            assert_eq!(code, DC_OK);
        }
        let ix = open_index(None);
        let mut out: *mut c_char = std::ptr::null_mut();
        assert_eq!(dc_index_status(ix, &mut out), DC_OK);
        dc_free(out.cast());
        dc_index_close(ix);

        assert_eq!(
            crate::audit::outstanding_allocations(),
            before,
            "AU-14：操作后未释放分配应为 0（相对增量，单线程执行）"
        );
    }
}
