# Rust 核心集成设计（方案 A：静态库 + C ABI）

> 状态：已接受（2026-08-01，方向定稿）；关联 [ADR-0004](decisions/0004-rust-core-index-engine.md)。
> 本文档沉淀「Rust 核心」的详细设计：集成形态、ABI、构建链、桥接、测试与失败模式。

## 1. 全景

一句话：**Rust 编译成静态库（staticlib），通过极小 C ABI 暴露给 Swift，
Swift 侧用协议 + 包装类隔离在 Indexing 模块里，UI 与业务层永远看不到 C 类型。**

```
Swift 侧                                     Rust 侧
SessionStore（事实源）
   ↓ 索引事件（IndexEventPublishing 协议）
IndexCoordinator（后台 actor）
   ↓ 调用 IndexService 协议
RustIndexService（FFI 包装）  ──C ABI──►  dc_index_open/upsert/search/...
   ↓                                   Rust 核心（embedding + 向量索引 + 重建）
索引文件（Application Support/com.deepseek.chat/index/）
```

核心原则：**索引是派生数据，SQLite 仍是事实源**。Rust 层可以整体删掉重建，
坏了不丢数据——这是方案 A 鲁棒性的根基。

## 2. 职责边界

| Rust 模块 | 职责 | 命名空间 / 入口 |
|---|---|---|
| history_index | 对话历史向量索引 | `dc_index_upsert/search`（namespace=history） |
| library_index | 资料库文件索引 + RAG | `dc_index_upsert/search`（namespace=library） |
| math_eval | 计算器（T0 工具） | `dc_eval_expr(json) -> json` |

不做：UI、网络层、会话持久化、通用 shell 执行。

## 3. 目录结构

```
DeepSeekChat/
├── RustCore/                        # Rust crate（独立子项目）
│   ├── Cargo.toml
│   ├── Cargo.lock                   # 入库，构建用 --locked
│   ├── src/
│   │   ├── lib.rs                   # crate-type = ["staticlib"]
│   │   ├── ffi.rs                   # C ABI 层（unsafe 全部收敛在此）
│   │   ├── engine.rs                # embedding + 向量索引核心
│   │   └── store.rs                 # 索引文件格式（版本化）
│   └── tests/                       # Rust 侧单测 / 集成测试
├── Sources/
│   ├── CRustCore/                   # SwiftPM C target
│   │   └── include/rustcore.h       # 手写头文件（初期 8~10 个函数）
│   ├── DeepSeekChatIndexing/        # Swift target：IndexService 协议 + RustIndexService
│   └── ...
└── scripts/
    ├── build-rust-core.sh           # cargo build → lipo → strip
    └── make-app.sh                  # 开头调用 build-rust-core.sh
```

`RustCore/target` 与产物目录进 `.gitignore`；`rustcore.h` 放
`Sources/CRustCore/include/` 由 SwiftPM 自动生成 `CRustCore` 模块。

## 4. Rust crate 设计

### 4.1 crate 形态

`crate-type = ["staticlib"]`，不碰 cdylib / dylib。静态库并入主二进制后，
签名、公证、Gatekeeper 自动覆盖；dylib 需单独签名与加载路径处理。

### 4.2 ABI 最小面

```c
typedef struct dc_index dc_index;          // 不透明句柄

dc_index *dc_index_open(const char *path, const char *config_json);  // 模型路径/维度/版本
void      dc_index_close(dc_index *ix);

int dc_index_upsert(dc_index *ix, const char *message_json);         // 消息/文件文档 JSON
int dc_index_delete(dc_index *ix, const char *message_id);
int dc_index_search(dc_index *ix, const char *query, const char *options_json,
                    char **out_json, void (*dc_free)(void *));
int dc_index_rebuild(dc_index *ix, const char *source_path);         // 从快照重建
int dc_index_status(dc_index *ix, char **out_json);
int dc_eval_expr(const char *expr_json, char **out_json, void (*dc_free)(void *));

void dc_index_cancel(dc_index *ix);                                  // 原子取消标志
int  dc_index_last_error(dc_index *ix, char *buf, size_t len);
```

设计要点：
- 复杂数据一律 JSON 出入（消息文档、查询、结果），**C 头不随业务字段演进**；
- 返回 int32 错误码（0=OK，负数=错误），详情走 `dc_index_last_error`；
- 长任务（重建、批量 embedding）提供 `dc_index_cancel`（原子标志）与
  进度回调（C 函数指针），Swift 侧转 `AsyncStream`。

### 4.3 内存所有权

| 数据 | 谁分配 | 谁释放 | 说明 |
|---|---|---|---|
| 输入 JSON | Swift（`withCString`） | Swift 自动 | Rust 同步拷贝，调用期间内存有效即可 |
| 输出 JSON | Rust | Swift 调 `dc_free` | 必须成对，封装在 `RustIndexService` 内部 |
| 句柄 | Rust | Rust（`dc_index_close`） | Swift 侧 actor 关闭 / deinit 时释放 |

### 4.4 panic 与错误

- release profile：`panic = "abort"`；FFI 层参数校验（空指针、非法长度）把
  可控错误转错误码，杜绝跨 FFI unwind；
- `unwrap` 只允许在纯 Rust 内部、有测试覆盖的路径；FFI 层全部 `Result` 化；
- `dc_index_last_error` 提供可读错误，Swift 映射成 `IndexError` 枚举。

### 4.5 embedding 选型联动

- `fastembed`（ONNX Runtime）会给 staticlib 带来 C++ 传递依赖（+20~60MB、
  链接与公证负担）——与方案 A 形态冲突；
- **`candle`（纯 Rust 推理）自包含**，是方案 A 下的优先选择；
- 向量索引：`usearch`（SIMD）或自写 brute-force，十万条内足够；数据量
  达标后再评估 HNSW；
- 测试用 `mock-embeddings` feature，单测不依赖真实模型。

## 5. 构建链路

### 5.1 build-rust-core.sh

```
1. cargo build --release --target aarch64-apple-darwin
2. cargo build --release --target x86_64-apple-darwin   # rustup target add 两个 target
3. lipo 合成 RustCore/dist/librustcore.a（universal）
4. strip（或 Cargo profile strip = true）
5. 可选：cbindgen --check 校验头文件与源码一致
```

`make-app.sh` 开头调用；dev 模式用 `--debug` 产物（保留符号，lldb 可下
Rust 断点），脚本支持 `MODE=debug`，CI 强制 release。

### 5.2 SwiftPM 集成

```swift
.target(
    name: "CRustCore",
    path: "Sources/CRustCore",
    linkerSettings: [
        .linkedLibrary("rustcore"),
        .unsafeFlags(["-L", "RustCore/dist"])   // 相对包根目录，统一从包根构建
    ]
),
.target(
    name: "DeepSeekChatIndexing",
    dependencies: ["CRustCore"]
)
```

- `.unsafeFlags` 代价：SwiftPM 关闭该 target 缓存（每次重编），且路径依赖
  「从包根构建」——项目统一由 `make-app.sh` 入口，风险可控；
- 正式分发升级路径：`.binaryTarget(path: "RustCore.xcframework")`，无
  unsafeFlags，SwiftPM 原生支持；初期不做的原因是 xcframework 目录结构
  更啰嗦、调试不如裸 `.a` 直观；
- 头文件初期手写；CI 加 `cbindgen --check` 防漂移。

## 6. Swift 侧桥接

### 6.1 协议（上层唯一契约）

```swift
protocol IndexService: Actor {
    func upsert(_ doc: IndexableMessage) async throws
    func delete(messageID: UUID, sessionID: UUID) async throws
    func search(_ query: String, scope: SearchScope, limit: Int) async throws -> [SearchHit]
    func rebuildIfNeeded() async throws
    var state: IndexState { get }   // ready / unavailable(reason)
}
```

### 6.2 RustIndexService 要点

- actor 串行化 FFI 入口；Rust 内 `RwLock` 允许只读并发搜索；
- 取消 / 进度：Swift `Task` 取消 → `dc_index_cancel()`；进度经 C 回调上抛；
- 降级：`dc_index_open` 失败 → `state = .unavailable`，UI 禁用搜索入口并
  提示原因，**应用其余功能不受影响**（与「数据库打不开退回内存库」同风格）；
- embedding 可注入：Rust 侧 `mock-embeddings` feature，Swift 集成测试不
  需要真模型。

### 6.3 事件流与线程

`SessionStore`（MainActor）经 `IndexEventPublishing` 发布事件 →
`IndexCoordinator`（后台 actor）消费 → `RustIndexService`（actor）→ FFI。
embedding 是 CPU 密集，单条增量走低优先级后台任务，重建走分片 +
进度 + 取消；**UI 主线程永不直接调 FFI**。

## 7. 分发、签名与 CI

- 签名 / 公证：静态库并进主二进制后 `codesign` 一把覆盖，无额外步骤
  （sidecar 的每个二进制需单独处理，这是方案 A 的优势）；
- CI 改造（lint / test / release 三 job）：
  - lint：`cargo fmt --check`、`cargo clippy -- -D warnings`、`cargo test`；
  - test：先 `build-rust-core.sh --debug` 再 `swift test`；rustup 双 target
    与 cargo registry 走 Actions 缓存；
  - release：`cargo build --release` + lipo + strip 再打包；
- 体积预算：纯 Rust 向量核心（candle + usearch，release + strip）预计
  2~8MB；模型文件作为资源单独放、不塞进 `.a`；预算写进 check-scale 扩展门禁。

## 8. 测试策略

| 层级 | 内容 | 运行位置 |
|---|---|---|
| Rust 单测 / 集成测试 | upsert / search / delete / rebuild、JSON 解析、错误码、取消语义（mock embeddings） | CI lint job |
| Swift 单测（现有 191 个） | 全部用 `MockIndexService`，与 Rust 无关 | `swift test`，无 cargo 也可跑 |
| FFI 集成测试 | 真调 `librustcore.a`：打开 / 写入 / 搜索 / 关闭、错误映射、内存释放成对 | 产物存在才跑，否则 `XCTSkip` |
| 性能基线 | XCTMeasure：搜索吞吐、批量 embedding、重建 10 万条耗时 | test job |

纪律：协议测试与 FFI 测试分开——上层只依赖 `IndexService` 协议，换实现
（Rust / 内存版 / 远程版）不动业务测试。

## 9. 版本与失败模式

- ABI / schema 版本：`dc_index_open` 的 config 携带 ABI 与索引 schema 版本，
  启动校验，不匹配自动 `rebuild`（有进度、可取消）；
- 索引可重建：内部格式变化 = 重建即迁移，无需用户数据迁移；
- 降级路径：模型缺失 → 语义搜索禁用、关键词（FTS5）可用；索引损坏 →
  自动重建；`.a` 链接失败 → 构建期问题，CI 拦截。

## 10. 风险清单

| 风险 | 应对 |
|---|---|
| cargo 构建链新增环境依赖 | 文档 + make-app.sh 自动检测；CI 缓存；无 cargo 时 `swift test` 仍可跑（集成测试 XCTSkip） |
| unsafeFlags 缓存关闭 / 相对路径 | 统一从包根构建；分发期换 xcframework |
| onnxruntime C++ 传递依赖 | 选 candle（纯 Rust），从根上消掉 |
| FFI 内存 / panic 错误 | ABI 最小面 + 所有权规则 + 错误码 + panic=abort + FFI 单测 |
| embedding 模型体积与首次延迟 | 模型资源化、int8 量化、后台预热、远程 embedding 可配置 |
| 双语言调试 | dev 模式 debug 库保留符号；FFI 层独立测试 |

## 11. 落地顺序

对应 TODO「Rust 核心与 AI 能力规划」的分层：先纯 Swift 地基（ContextBuilder、
授权、SessionSummary），再 Rust 骨架与构建链，然后资料库 RAG、工具沙箱、
最后长时推演。每步独立可合并、可回滚。
