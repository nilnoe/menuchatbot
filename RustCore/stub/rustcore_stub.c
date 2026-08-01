/*
 * 无 cargo 环境下的降级实现（T2-1d）。
 *
 * 由 scripts/build-rust-core.sh 用 Xcode CLT 自带的 cc/ar 编译成
 * RustCore/dist/librustcore.a，与真实 Rust 库保持相同 C ABI，使
 * swift build / swift test 在无 Rust 工具链时仍可链接运行。
 * 所有入口返回 DC_ERR_UNAVAILABLE；FFI 集成测试检测
 * RustCore/dist/.stub 标记后 XCTSkip。
 */
#include "rustcore.h"
#include <stdlib.h>

dc_index *dc_index_open(const char *path, const char *config_json)
{
    (void)path;
    (void)config_json;
    return NULL;
}

void dc_index_close(dc_index *ix)
{
    (void)ix;
}

int dc_index_upsert(dc_index *ix, const char *message_json)
{
    (void)ix;
    (void)message_json;
    return DC_ERR_UNAVAILABLE;
}

int dc_index_delete(dc_index *ix, const char *message_id)
{
    (void)ix;
    (void)message_id;
    return DC_ERR_UNAVAILABLE;
}

int dc_index_search(dc_index *ix, const char *query, const char *options_json,
                    char **out_json, void (*dc_free_cb)(void *))
{
    (void)ix;
    (void)query;
    (void)options_json;
    (void)dc_free_cb;
    if (out_json != NULL) {
        *out_json = NULL;
    }
    return DC_ERR_UNAVAILABLE;
}

int dc_index_rebuild(dc_index *ix, const char *source_path)
{
    (void)ix;
    (void)source_path;
    return DC_ERR_UNAVAILABLE;
}

int dc_index_status(dc_index *ix, char **out_json)
{
    (void)ix;
    if (out_json != NULL) {
        *out_json = NULL;
    }
    return DC_ERR_UNAVAILABLE;
}

void dc_index_cancel(dc_index *ix)
{
    (void)ix;
}

int dc_index_last_error(dc_index *ix, char *buf, size_t len)
{
    (void)ix;
    (void)buf;
    (void)len;
    return 0;
}

int dc_eval_expr(const char *expr_json, char **out_json, void (*dc_free_cb)(void *))
{
    (void)expr_json;
    (void)dc_free_cb;
    if (out_json != NULL) {
        *out_json = NULL;
    }
    return DC_ERR_UNAVAILABLE;
}

void dc_audit_init(const char *log_path)
{
    (void)log_path;
}

int dc_audit_snapshot(char **out_json)
{
    if (out_json != NULL) {
        *out_json = NULL;
    }
    return DC_ERR_UNAVAILABLE;
}

void dc_free(void *ptr)
{
    free(ptr);
}
