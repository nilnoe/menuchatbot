//! 审计与可观测性（ADR-0009 P2，域 E）。
//!
//! 进程级状态：错误码计数器、调用计数、分配 / 释放配对计数、panic
//! 环形缓冲与崩溃日志。全部原子 / 互斥保护，零第三方依赖（离线可构建）。
//! 对应验收 AU-13（计数一致）/ AU-14（无泄漏）/ AU-15（panic 可观测）。

use crate::json::{self, Json};
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Mutex;

static TOTAL_CALLS: AtomicU64 = AtomicU64::new(0);
static OUTSTANDING_ALLOCATIONS: AtomicI64 = AtomicI64::new(0);
static PANIC_COUNT: AtomicU64 = AtomicU64::new(0);
/// 错误码计数，下标 = (-code) 映射到 0..=6（DC_OK 在 0）。
static ERROR_COUNTS: Mutex<[u64; 7]> = Mutex::new([0; 7]);
static PANIC_RING: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
static CRASH_LOG_PATH: Mutex<Option<String>> = Mutex::new(None);

const PANIC_RING_CAPACITY: usize = 16;

/// FFI 入口调用计数（每个导出函数进入时调用）。
pub fn record_call() {
    TOTAL_CALLS.fetch_add(1, Ordering::Relaxed);
}

/// 记录一次错误码返回（0 = OK 不记；越界码忽略）。
pub fn record_error(code: i32) {
    if code == 0 {
        return;
    }
    let index = (-code).clamp(0, 6) as usize;
    if let Ok(mut counts) = ERROR_COUNTS.lock() {
        counts[index] = counts[index].saturating_add(1);
    }
}

/// 记一次本库分配（write_out / 句柄 open 成功）。
pub fn record_allocated() {
    OUTSTANDING_ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
}

/// 记一次本库释放（dc_free / 句柄 close）。
pub fn record_freed() {
    OUTSTANDING_ALLOCATIONS.fetch_sub(1, Ordering::Relaxed);
}

pub fn outstanding_allocations() -> i64 {
    OUTSTANDING_ALLOCATIONS.load(Ordering::Relaxed)
}

/// 设置崩溃日志路径（dc_audit_init；None = 只记环形缓冲）。
pub fn set_crash_log_path(path: Option<String>) {
    if let Ok(mut slot) = CRASH_LOG_PATH.lock() {
        *slot = path;
    }
}

/// 安装 panic hook：先把现场写入环形缓冲与崩溃日志，再调用默认 hook
/// （保留既有 panic 输出与 `panic = "abort"` 语义）。进程内只装一次。
pub fn install_panic_hook() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            record_panic(info);
            previous(info);
        }));
    });
}

fn record_panic(info: &std::panic::PanicHookInfo<'_>) {
    PANIC_COUNT.fetch_add(1, Ordering::Relaxed);
    let message = panic_message(info);
    if let Ok(mut ring) = PANIC_RING.lock() {
        if ring.len() >= PANIC_RING_CAPACITY {
            ring.pop_front();
        }
        ring.push_back(message.clone());
    }
    append_crash_log(&message);
}

fn panic_message(info: &std::panic::PanicHookInfo<'_>) -> String {
    let payload = if let Some(s) = info.payload().downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = info.payload().downcast_ref::<String>() {
        s.clone()
    } else {
        "non-string panic payload".to_string()
    };
    let location = info
        .location()
        .map(|loc| loc.to_string())
        .unwrap_or_else(|| "unknown location".to_string());
    format!("panic: {} @ {}", payload, location)
}

fn append_crash_log(message: &str) {
    let path = CRASH_LOG_PATH.lock().ok().and_then(|slot| slot.clone());
    let Some(path) = path else { return };
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!("[{epoch}] {message}\n");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = file.write_all(line.as_bytes());
    }
}

/// 审计快照（`dc_audit_snapshot` 的数据源）。
pub fn snapshot() -> Json {
    let counts = ERROR_COUNTS.lock().unwrap_or_else(|e| e.into_inner());
    let error_object = Json::Object(
        [0, -1, -2, -3, -4, -5, -6]
            .iter()
            .enumerate()
            .map(|(index, code)| {
                let value = Json::Number(json::Number::Int(counts[index] as i64));
                (code.to_string(), value)
            })
            .collect(),
    );
    let recent = PANIC_RING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .cloned()
        .map(Json::String)
        .collect();
    Json::object(vec![
        ("version", Json::Number(json::Number::Int(1))),
        (
            "total_calls",
            Json::Number(json::Number::Int(TOTAL_CALLS.load(Ordering::Relaxed) as i64)),
        ),
        (
            "outstanding_allocations",
            Json::Number(json::Number::Int(
                OUTSTANDING_ALLOCATIONS.load(Ordering::Relaxed),
            )),
        ),
        (
            "panic_count",
            Json::Number(json::Number::Int(PANIC_COUNT.load(Ordering::Relaxed) as i64)),
        ),
        ("error_counts", error_object),
        ("recent_panics", Json::Array(recent)),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_counts_map_by_code() {
        // 单线程执行（CI：cargo test -- --test-threads=1）下精确断言。
        let counts_before = *ERROR_COUNTS.lock().unwrap();
        record_error(-1);
        record_error(-1);
        record_error(-5);
        record_error(0); // OK 不记
        let counts = ERROR_COUNTS.lock().unwrap();
        assert_eq!(counts[1] - counts_before[1], 2);
        assert_eq!(counts[5] - counts_before[5], 1);
        assert_eq!(counts[0] - counts_before[0], 0);
    }

    #[test]
    fn allocation_pairing() {
        let before = outstanding_allocations();
        record_allocated();
        record_allocated();
        record_freed();
        // 中间态不做精确断言（并行下全局计数）；只验证最终配对归零。
        record_freed();
        assert_eq!(outstanding_allocations(), before);
    }

    #[test]
    fn panic_hook_records_message_and_location() {
        install_panic_hook();
        let before = PANIC_COUNT.load(Ordering::Relaxed);
        let caught = std::panic::catch_unwind(|| {
            panic!("审计测试注入的 panic");
        });
        assert!(caught.is_err(), "catch_unwind 应捕获注入 panic");
        assert_eq!(
            PANIC_COUNT.load(Ordering::Relaxed),
            before + 1,
            "AU-15：panic 计数应 +1"
        );
        let ring = PANIC_RING.lock().unwrap();
        let last = ring.back().expect("环形缓冲应有记录");
        assert!(
            last.contains("审计测试注入的 panic") && last.contains("audit.rs"),
            "AU-15：环形缓冲应含消息与位置，实际：{last}"
        );
    }
}
