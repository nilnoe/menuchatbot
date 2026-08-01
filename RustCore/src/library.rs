//! 资料库文件索引（Tier 3-1，ADR-0005 D2/D3）：
//! 根目录扫描 / 分块 / 增量 / 扩展名白名单。
//!
//! 安全边界：
//! - 只扫描授权根目录（规范化 + symlink 解析后的路径包含检查，逃逸一律拒绝）；
//! - 跳过隐藏文件 / 目录、超大文件、二进制文件、常见依赖目录；
//! - 索引是派生数据：`IndexCore` 可整体删除重建，SQLite 仍是事实源。

use crate::engine::fnv1a;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// 默认单文件上限（5MB；超出跳过并计数）。
pub const DEFAULT_MAX_FILE_BYTES: u64 = 5 * 1024 * 1024;
/// 默认分块目标（token）：落在 ADR-0005 的 500~800 区间中部。
pub const DEFAULT_CHUNK_TOKENS: usize = 600;
/// 默认分块重叠（token）：相邻块共享尾部，避免语义被切碎。
pub const DEFAULT_OVERLAP_TOKENS: usize = 120;
/// 默认扩展名白名单（文本类，可配置覆盖）。
pub const DEFAULT_EXTENSIONS: &[&str] = &[
    "md", "markdown", "txt", "swift", "rs", "py", "json", "yaml", "yml", "js", "ts", "tsx", "jsx",
    "html", "css", "c", "h", "hpp", "cpp", "sh", "toml", "sql", "csv", "xml",
];
/// 默认忽略的依赖 / 产物目录（按名字匹配，避免索引 node_modules 等）。
const IGNORED_DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    ".build",
    "target",
    "node_modules",
    "dist",
    "build",
    "vendor",
    "Pods",
    "DerivedData",
    "__pycache__",
    ".venv",
    "venv",
    ".idea",
    ".vscode",
];
/// 二进制嗅探读取字节数（前 8KB 出现 NUL 视为二进制）。
const BINARY_SNIFF_BYTES: usize = 8192;

/// 扫描 / 分块配置（FFI options JSON 可覆盖全部字段）。
#[derive(Debug, Clone, PartialEq)]
pub struct ScanOptions {
    pub extensions: Vec<String>,
    pub max_file_bytes: u64,
    pub chunk_tokens: usize,
    pub overlap_tokens: usize,
    pub ignored_dirs: Vec<String>,
}

impl Default for ScanOptions {
    fn default() -> Self {
        Self {
            extensions: DEFAULT_EXTENSIONS.iter().map(|s| s.to_string()).collect(),
            max_file_bytes: DEFAULT_MAX_FILE_BYTES,
            chunk_tokens: DEFAULT_CHUNK_TOKENS,
            overlap_tokens: DEFAULT_OVERLAP_TOKENS,
            ignored_dirs: IGNORED_DIRS.iter().map(|s| s.to_string()).collect(),
        }
    }
}

/// 扫描结果：命中的文件列表 + 跳过计数（隐藏 / 白名单外 / 超大 / 二进制 / 逃逸）。
#[derive(Debug, Clone, PartialEq)]
pub struct ScanResult {
    pub files: Vec<PathBuf>,
    pub skipped: usize,
}

/// 规范化根目录：解析 symlink 后必须是目录。
pub fn canonicalize_root(root: &Path) -> Result<PathBuf, String> {
    let canonical =
        fs::canonicalize(root).map_err(|e| format!("无法访问根目录 {}: {}", root.display(), e))?;
    if !canonical.is_dir() {
        return Err(format!("根目录不是文件夹: {}", root.display()));
    }
    Ok(canonical)
}

/// 路径包含检查（规范化后）：候选路径必须在根目录内且不等于根目录。
pub fn is_contained(root: &Path, candidate: &Path) -> bool {
    candidate.starts_with(root) && candidate != root
}

/// 递归扫描根目录：返回规范化后的文件路径（全部在根内）。
pub fn scan(root: &Path, options: &ScanOptions) -> Result<ScanResult, String> {
    let root = canonicalize_root(root)?;
    let mut files = Vec::new();
    let mut skipped = 0usize;
    let mut visited = HashSet::new();
    walk(
        &root,
        &root,
        options,
        &mut files,
        &mut skipped,
        &mut visited,
    )?;
    Ok(ScanResult { files, skipped })
}

fn walk(
    root: &Path,
    dir: &Path,
    options: &ScanOptions,
    files: &mut Vec<PathBuf>,
    skipped: &mut usize,
    visited: &mut HashSet<PathBuf>,
) -> Result<(), String> {
    if !visited.insert(dir.to_path_buf()) {
        return Ok(()); // symlink 环保护
    }
    let entries =
        fs::read_dir(dir).map_err(|e| format!("读取目录 {} 失败: {}", dir.display(), e))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("读取目录项失败: {}", e))?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with('.') {
            *skipped += 1;
            continue;
        }
        let path = entry.path();
        // 统一解析 symlink：规范化后再做包含检查与类型判断。
        let resolved = match fs::canonicalize(&path) {
            Ok(p) => p,
            Err(_) => {
                *skipped += 1; // 断链 / 无权限等不可读项
                continue;
            }
        };
        if !is_contained(root, &resolved) {
            *skipped += 1; // symlink 逃逸：拒绝
            continue;
        }
        let meta = match fs::metadata(&resolved) {
            Ok(m) => m,
            Err(_) => {
                *skipped += 1;
                continue;
            }
        };
        if meta.is_dir() {
            if options
                .ignored_dirs
                .iter()
                .any(|ignored| ignored == &name_str)
            {
                *skipped += 1;
                continue;
            }
            walk(root, &resolved, options, files, skipped, visited)?;
        } else if meta.is_file() {
            if !options
                .extensions
                .iter()
                .any(|ext| extension_matches(&resolved, ext))
            {
                *skipped += 1;
                continue;
            }
            if meta.len() > options.max_file_bytes {
                *skipped += 1;
                continue;
            }
            if is_binary(&resolved) {
                *skipped += 1;
                continue;
            }
            files.push(resolved);
        } else {
            *skipped += 1; // socket / fifo / 设备文件
        }
    }
    Ok(())
}

fn extension_matches(path: &Path, expected: &str) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|ext| ext.eq_ignore_ascii_case(expected))
        .unwrap_or(false)
}

fn is_binary(path: &Path) -> bool {
    let Ok(bytes) = fs::read(path) else {
        return true;
    };
    bytes.iter().take(BINARY_SNIFF_BYTES).any(|&b| b == 0)
}

/// CJK（含假名 / 谚文）1 字符 ≈ 1 token；与 Swift 侧 CharacterTokenEstimator 对齐。
pub fn is_cjk(c: char) -> bool {
    let value = c as u32;
    (0x4E00..=0x9FFF).contains(&value)
        || (0x3400..=0x4DBF).contains(&value)
        || (0xF900..=0xFAFF).contains(&value)
        || (0x3040..=0x30FF).contains(&value)
        || (0xAC00..=0xD7AF).contains(&value)
}

/// 分块结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Chunk {
    pub text: String,
    pub index: usize,
}

/// 分段：CJK 单字符为一段（权重 1）；非 CJK 连续串为一段（4 字符 ≈ 1 token）。
#[derive(Debug, Clone, PartialEq)]
struct Segment {
    text: String,
    weight: usize,
}

/// 文本分块：目标 `target_tokens`，相邻块尾部重叠 `overlap_tokens`。
/// 单块不超过 target（超大非 CJK 段会先按权重切片）；结果至少 1 块。
pub fn chunk_text(text: &str, target_tokens: usize, overlap_tokens: usize) -> Vec<Chunk> {
    let target = target_tokens.max(64);
    let overlap = overlap_tokens.min(target / 2);
    let segments = split_oversized(segment(text), target);

    let mut chunks: Vec<Chunk> = Vec::new();
    let mut current: Vec<Segment> = Vec::new();
    let mut current_weight = 0usize;

    for original in segments {
        let mut seg = original;
        // 保证单块 ≤ target：超出时先从 seg 头部切下能填满当前块的量。
        while current_weight + seg.weight > target && !current.is_empty() {
            let fit = target - current_weight;
            if fit > 0 {
                let (head, tail) = split_by_weight(seg, fit);
                current.push(head);
                current_weight += fit;
                seg = tail;
            }
            emit_chunk(&mut chunks, &mut current, &mut current_weight, overlap);
        }
        current_weight += seg.weight;
        current.push(seg);
    }
    if !current.is_empty() {
        chunks.push(Chunk {
            text: join_segments(&current),
            index: chunks.len(),
        });
    }
    chunks
}

/// 发射当前块并携带尾部重叠段（保证后续块上下文连续）。
fn emit_chunk(
    chunks: &mut Vec<Chunk>,
    current: &mut Vec<Segment>,
    current_weight: &mut usize,
    overlap: usize,
) {
    if current.is_empty() {
        return;
    }
    chunks.push(Chunk {
        text: join_segments(current),
        index: chunks.len(),
    });
    let mut carried: Vec<Segment> = Vec::new();
    let mut carried_weight = 0usize;
    for s in current.iter().rev() {
        if carried_weight + s.weight > overlap {
            if carried.is_empty() {
                // 单段超重：只携带其尾部 overlap 权重（避免下一块起步即满）。
                let tail = tail_segment(s, overlap);
                carried_weight += tail.weight;
                carried.push(tail);
            }
            break;
        }
        carried.push(s.clone());
        carried_weight += s.weight;
    }
    carried.reverse();
    *current = carried;
    *current_weight = carried_weight;
}

/// 取段尾部：权重 ≤ max_weight 时原样返回，否则按 4 字符 ≈ 1 token 截尾。
fn tail_segment(seg: &Segment, max_weight: usize) -> Segment {
    if seg.weight <= max_weight {
        return seg.clone();
    }
    let chars: Vec<char> = seg.text.chars().collect();
    let take_from_end = (max_weight * 4).min(chars.len());
    let start = chars.len() - take_from_end;
    let text: String = chars[start..].iter().collect();
    Segment {
        weight: head_weight(&text),
        text,
    }
}

/// 按权重切分段：head 权重 ≤ max_weight，tail 为剩余（可能为空）。
fn split_by_weight(seg: Segment, max_weight: usize) -> (Segment, Segment) {
    if seg.weight <= max_weight {
        return (
            seg,
            Segment {
                text: String::new(),
                weight: 0,
            },
        );
    }
    let chars: Vec<char> = seg.text.chars().collect();
    // 非 CJK 段 weight = ceil(len/4)：取 4 × max_weight 个字符即可满足权重上限。
    let take = (max_weight * 4).min(chars.len());
    let head_text: String = chars[..take].iter().collect();
    let tail_text: String = chars[take..].iter().collect();
    let head = Segment {
        weight: head_weight(&head_text),
        text: head_text,
    };
    let tail = Segment {
        weight: head_weight(&tail_text),
        text: tail_text,
    };
    (head, tail)
}

fn head_weight(text: &str) -> usize {
    if text.is_empty() {
        0
    } else {
        text.chars().count().div_ceil(4).max(1)
    }
}

fn segment(text: &str) -> Vec<Segment> {
    let mut segments = Vec::new();
    let mut run = String::new();
    for c in text.chars() {
        if is_cjk(c) {
            if !run.is_empty() {
                let weight = run.chars().count().div_ceil(4);
                segments.push(Segment {
                    text: std::mem::take(&mut run),
                    weight,
                });
            }
            segments.push(Segment {
                text: c.to_string(),
                weight: 1,
            });
        } else {
            run.push(c);
        }
    }
    if !run.is_empty() {
        let weight = run.chars().count().div_ceil(4);
        segments.push(Segment { text: run, weight });
    }
    segments
}

/// 把权重超过 target 的单段按 target 权重切片（仅超大非 CJK 段会命中）。
fn split_oversized(segments: Vec<Segment>, target: usize) -> Vec<Segment> {
    let mut out = Vec::with_capacity(segments.len());
    for seg in segments {
        if seg.weight <= target {
            out.push(seg);
            continue;
        }
        let chars: Vec<char> = seg.text.chars().collect();
        let per_slice = (target * 4).max(64);
        let mut i = 0;
        while i < chars.len() {
            let end = (i + per_slice).min(chars.len());
            let slice: String = chars[i..end].iter().collect();
            let weight = slice.chars().count().div_ceil(4).max(1);
            out.push(Segment {
                text: slice,
                weight,
            });
            i = end;
        }
    }
    out
}

fn join_segments(segments: &[Segment]) -> String {
    let mut out = String::new();
    for seg in segments {
        out.push_str(&seg.text);
    }
    out
}

/// 文件元信息（增量判定：path + mtime + contentHash，ADR-0005 D3）。
#[derive(Debug, Clone, PartialEq)]
pub struct FileEntry {
    pub path: String,
    pub mtime_ns: i64,
    pub content_hash: String,
    pub file_size: u64,
}

impl FileEntry {
    /// 从磁盘元信息 + 内容构造（内容哈希 FNV-1a 64 十六进制）。
    pub fn from_disk(path: &Path, content: &[u8]) -> Result<Self, String> {
        let meta =
            fs::metadata(path).map_err(|e| format!("读取元信息失败 {}: {}", path.display(), e))?;
        let mtime_ns = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_nanos() as i64)
            .unwrap_or(0);
        Ok(Self {
            path: path.to_string_lossy().into_owned(),
            mtime_ns,
            content_hash: format!("{:016x}", fnv1a(content)),
            file_size: content.len() as u64,
        })
    }

    /// 是否与既有记录一致（mtime + hash + size 全同才跳过）。
    pub fn unchanged(&self, other: &FileEntry) -> bool {
        self.mtime_ns == other.mtime_ns
            && self.content_hash == other.content_hash
            && self.file_size == other.file_size
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_text_respects_target_and_overlap() {
        let text: String = (0..80).map(|i| format!("单词{} 内容 ", i)).collect();
        let chunks = chunk_text(&text, 100, 20);
        assert!(chunks.len() >= 2, "80 个 token 段按 100 目标应至少 2 块");
        for chunk in &chunks {
            let weight = chunk.text.chars().count().div_ceil(4);
            assert!(weight <= 100, "单块不超过 target：{}", weight);
        }
        // 重叠：相邻块共享上一块尾部文本。
        if chunks.len() >= 2 {
            let chunk0_tail: String = chunks[0]
                .text
                .chars()
                .rev()
                .take(8)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            assert!(chunks[1].text.contains(&chunk0_tail), "相邻块应有重叠内容");
        }
    }

    #[test]
    fn chunk_text_cjk_counted_as_single_token() {
        let text = "苹果与香蕉都是水果。".repeat(120);
        let chunks = chunk_text(&text, 100, 20);
        assert!(chunks.len() >= 2);
        for chunk in &chunks {
            let weight = chunk.text.chars().count();
            assert!(weight <= 100, "CJK 1 字符 = 1 token：{}", weight);
        }
    }

    #[test]
    fn chunk_text_splits_oversized_run() {
        let text = "a".repeat(10_000);
        let chunks = chunk_text(&text, 100, 20);
        assert!(chunks.len() > 1);
        for chunk in &chunks {
            let weight = chunk.text.chars().count().div_ceil(4);
            assert!(weight <= 100, "超大段应切片：{}", weight);
        }
    }

    #[test]
    fn scan_respects_extension_whitelist_and_hidden() {
        let dir = std::env::temp_dir().join(format!("dc_scan_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.md"), "内容").unwrap();
        fs::write(dir.join("b.txt"), "内容").unwrap();
        fs::write(dir.join("c.swift"), "内容").unwrap();
        fs::write(dir.join("d.exe"), b"\x00\x01binary").unwrap();
        fs::write(dir.join(".hidden.md"), "内容").unwrap();
        fs::write(dir.join("e.log"), "内容").unwrap(); // 白名单外

        let options = ScanOptions::default();
        let result = scan(&dir, &options).unwrap();
        let names: Vec<String> = result
            .files
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert!(names.contains(&"a.md".to_string()));
        assert!(names.contains(&"b.txt".to_string()));
        assert!(names.contains(&"c.swift".to_string()));
        assert!(!names.contains(&"d.exe".to_string()), "二进制应跳过");
        assert!(!names.contains(&".hidden.md".to_string()), "隐藏文件应跳过");
        assert!(!names.contains(&"e.log".to_string()), "白名单外应跳过");
        assert_eq!(result.skipped, 3);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_rejects_symlink_escape() {
        let dir = std::env::temp_dir().join(format!("dc_escape_test_{}", std::process::id()));
        let outside = std::env::temp_dir().join(format!("dc_outside_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&outside);
        fs::create_dir_all(&dir).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("secret.md"), "机密内容").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, dir.join("escape")).unwrap();

        let options = ScanOptions::default();
        let result = scan(&dir, &options).unwrap();
        assert!(result.files.is_empty(), "symlink 逃逸文件必须被拒绝");
        assert_eq!(result.skipped, 1);
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&outside);
    }

    #[test]
    fn scan_skips_ignored_dirs_and_oversized() {
        let dir = std::env::temp_dir().join(format!("dc_ignore_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("node_modules")).unwrap();
        fs::create_dir_all(dir.join("docs")).unwrap();
        fs::write(dir.join("node_modules/x.md"), "依赖内容").unwrap();
        fs::write(dir.join("docs/keep.md"), "文档内容").unwrap();
        fs::write(dir.join("big.md"), "x".repeat(200)).unwrap();

        let options = ScanOptions {
            max_file_bytes: 100,
            ..ScanOptions::default()
        };
        let result = scan(&dir, &options).unwrap();
        let names: Vec<String> = result
            .files
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert!(names.contains(&"keep.md".to_string()));
        assert!(!names.contains(&"x.md".to_string()), "node_modules 应跳过");
        assert!(!names.contains(&"big.md".to_string()), "超大文件应跳过");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn file_entry_unchanged_detection() {
        let dir = std::env::temp_dir().join(format!("dc_entry_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.md");
        fs::write(&path, "v1 内容").unwrap();
        let first = FileEntry::from_disk(&path, "v1 内容".as_bytes()).unwrap();
        let second = FileEntry::from_disk(&path, "v1 内容".as_bytes()).unwrap();
        assert!(
            first.unchanged(&second),
            "同 mtime + hash + size 应视为未变"
        );
        fs::write(&path, "v2 内容变长").unwrap();
        let third = FileEntry::from_disk(&path, "v2 内容变长".as_bytes()).unwrap();
        assert!(!first.unchanged(&third), "内容变化应判定为已变");
        let _ = fs::remove_dir_all(&dir);
    }
}
