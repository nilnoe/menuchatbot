#ifndef RUSTCORE_H
#define RUSTCORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * DeepSeek Chat Rust 核心 C ABI（Tier 2 骨架 + Tier 3 资料库）。
 *
 * 约定（详见 docs/DESIGN_RUST_CORE.md §4）：
 * - 返回 int32 错误码：0 = 成功（DC_OK），负数 = 错误；
 * - 复杂数据一律 JSON 出入，本头不随业务字段演进；
 * - 输出 JSON（char **out_json）由 Rust 分配，调用方必须用 dc_free 释放；
 *   `dc_free_cb` 回调参数保留兼容，当前实现忽略它，请传 NULL；
 * - 所有入口对非法参数返回错误码，不会跨 FFI panic。
 */

/* 错误码（与 RustCore/src/ffi.rs 保持一致，勿单边改动） */
#define DC_OK                   0
#define DC_ERR_INVALID_ARGUMENT (-1)
#define DC_ERR_JSON             (-2)
#define DC_ERR_NOT_FOUND        (-3)
#define DC_ERR_UNAVAILABLE      (-4)
#define DC_ERR_INTERNAL         (-5)
#define DC_ERR_CANCELLED        (-6)

typedef struct dc_index dc_index;

/* ---- 索引句柄生命周期 ---- */

/* 打开索引。path 为索引落盘目录（可 NULL = 纯内存）；config_json 形如
   {"namespace":"history","version":2}。失败返回 NULL。 */
dc_index *dc_index_open(const char *path, const char *config_json);

void dc_index_close(dc_index *ix);

/* ---- 索引操作 ---- */

/* message_json 形如 {"id":"...","content":"...","namespace"?: "..."} */
int dc_index_upsert(dc_index *ix, const char *message_json);

int dc_index_delete(dc_index *ix, const char *message_id);

/* query 为关键词文本；options_json 形如 {"limit"?: N, "namespace"?: "..."}。
   成功时 out_json = {"hits":[{"id","score","content"}],"count":N}。 */
int dc_index_search(dc_index *ix, const char *query, const char *options_json,
                    char **out_json, void (*dc_free_cb)(void *));

/* 重建：source_path 为 JSON 数组快照路径；NULL 时仅清空。 */
int dc_index_rebuild(dc_index *ix, const char *source_path);

/* 成功时 out_json = {"version","document_count","namespace","ready",
   "files","indexed_at"}（library 命名空间含资料库统计）。 */
int dc_index_status(dc_index *ix, char **out_json);

/* 请求取消当前长操作（资料库索引 / 重建）：操作级标志，开始前自动清零，
   不影响搜索与写入（Tier 3 按操作 token 语义）。 */
void dc_index_cancel(dc_index *ix);

/* 资料库增量索引：扫描 root_path（规范化 + symlink 包含检查，拒绝逃逸），
   按扩展名白名单分块（500~800 token 带重叠，默认 600/120），以
   path + mtime + contentHash 增量更新（未变文件不重 embed）。
   options_json 形如 {"corpus_id":"...","corpus_name":"...",
   "extensions":[...],"max_file_bytes":N,"chunk_tokens":N,"overlap_tokens":N}，
   全部字段可选。成功时 out_json = {"corpus_id","corpus_name",
   "files_scanned","files_indexed","files_skipped","files_removed",
   "chunks_added","chunks_total","duration_ms"}。 */
int dc_index_index_corpus(dc_index *ix, const char *root_path,
                          const char *options_json, char **out_json,
                          void (*dc_free_cb)(void *));

/* 拷贝最近一次错误到 buf（最多 len-1 字节 + NUL），返回写入字节数。 */
int dc_index_last_error(dc_index *ix, char *buf, size_t len);

/* ---- T0 计算器 ---- */

/* expr_json 形如 {"expr":"1 + 2*3"}。
   成功 out_json = {"ok":true,"value":7}；失败返回负错误码且
   out_json = {"ok":false,"error":"..."}（不 panic）。 */
int dc_eval_expr(const char *expr_json, char **out_json, void (*dc_free_cb)(void *));

/* ---- 审计与可观测性（ADR-0009 P2）---- */

/* 一次性安装 panic hook 并设置崩溃日志路径（可传 NULL = 不落文件）。
 * 幂等：进程内多次调用只安装一次。 */
void dc_audit_init(const char *log_path);

/* 导出审计快照：{"version","total_calls","outstanding_allocations",
 * "panic_count","error_counts","recent_panics"}；JSON 由 dc_free 释放。
 * stub 降级环境返回 DC_ERR_UNAVAILABLE 且 out_json 置 NULL。 */
int dc_audit_snapshot(char **out_json);

/* ---- 内存所有权 ---- */

/* 释放本库分配的输出 JSON；与 dc_index_search / dc_index_status /
   dc_eval_expr 的 out_json 成对使用。 */
void dc_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* RUSTCORE_H */
