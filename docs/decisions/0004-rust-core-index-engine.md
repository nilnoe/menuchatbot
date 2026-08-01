# ADR-0004：Rust 核心集成（方案 A：静态库 + C ABI）

- 状态：已接受（2026-08-01，方向定稿；构建细节落地时验证）
- 关联：[DESIGN_RUST_CORE](../DESIGN_RUST_CORE.md)、TODO「Rust 核心与 AI 能力规划」

## 背景

为支撑本地向量检索（对话历史 + 用户资料库）与确定性计算（表达式求值），
决定引入 Rust 作为核心模块。需在「纯原生、无运行时服务进程」约束下确定
集成形态与职责边界。

## 决策

### D1：静态库 + 最小 C ABI（方案 A）

Rust 编译为 `staticlib`，通过手写头文件（初期 8~10 个函数）暴露极小 C 面，
Swift 侧用 SwiftPM C target + module map 桥接，并包一层 Swift 协议。产物并进
主二进制，签名 / 公证自动覆盖。

否决 sidecar 进程（违反「无运行时服务进程」约束、需管理进程生命周期与签名）
与 dylib（需单独签名与加载路径处理）。

### D2：Rust 只拥有「派生索引」，SQLite 仍是事实源

索引文件可整体重建（从 SQLite 快照回放）；启动校验索引版本，不一致自动
`rebuild`（有进度、可取消）。索引损坏不丢数据。

### D3：职责边界

Rust 核心 = 对话历史索引（`history_index`）+ 资料库文件索引（`library_index`）
+ 计算器求值（`math_eval`）。不做 UI、不做网络层、不做会话持久化。

### D4：embedding 选型优先 candle（纯 Rust）

`fastembed` 依赖 ONNX Runtime（C++ 传递依赖、体积 +20~60MB、链接与公证负担），
与 staticlib 形态冲突；`candle` 自包含、无 C++ 传递依赖。向量索引用 usearch
或自写 SIMD brute-force，数据量达标后再评估 HNSW。测试用 `mock-embeddings`
feature，避免单测依赖真实模型。

### D5：ABI 最小面 + JSON 出入 + 所有权规则

复杂数据一律 JSON 出入（消息文档、查询、结果），C 头不随业务字段演进。
输入内存由 Swift 持有（Rust 同步拷贝）；输出由 Rust 分配、Swift 经
`dc_free` 释放。`panic = "abort"` + FFI 层参数校验与错误码，禁止跨 FFI unwind。

### D6：构建链

`scripts/build-rust-core.sh`（cargo → 双架构 target → lipo → strip）接入
`make-app.sh` 与 CI；SwiftPM 用 `CRustCore` C target +
`linkedLibrary("rustcore")` + `unsafeFlags(-L RustCore/dist)`；
正式分发时升级 xcframework `.binaryTarget`。`Cargo.lock` 入库，构建用
`--locked`。

### D7：Swift 侧协议隔离

`IndexService`（及后续 `LibraryIndexService`）是上层唯一契约；
`MockIndexService` 供测试；UI 永不接触 C 类型。索引事件由 `SessionStore`
经 `IndexEventPublishing` 发布，`IndexCoordinator` 后台消费。

## 后果

**正面**：进程内高性能、无 IPC、符合纯原生约束、索引可整体重建。

**代价**：双语言构建链；`unsafeFlags` 关闭 SwiftPM 缓存；FFI 调试成本
（dev 模式链接 debug 库保留符号）。

## 备选方案

- Sidecar 进程（JSON-RPC / 本地 socket）：崩溃隔离好，但违反现有工程约束，
  且进程生命周期、签名、升级都要管理，否决。
- 纯 Swift（FTS5 + Core ML / NaturalLanguage）：无需 Rust，但语义检索算法
  自由度与内存确定性受限；保留作为性能对比基线（benchmark 门禁）。
