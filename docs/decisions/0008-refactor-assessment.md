# ADR-0008：重构评估与执行顺序（数据瓶颈 + 接口边界）

- 状态：已接受（2026-08-01）
- 关联：ADR-0001（分层与流式边界）、ADR-0004~0007（Rust 核心与 AI 能力）、
  TODO「Rust 核心与 AI 能力规划」Tier 1

## 背景

开始 Tier 1~5 功能开发前，需要先回答「项目是否需要重构、改什么、按什么
顺序」。评估基线：现状代码（main a4bc208）、既有 ADR 与性能基线测试。

## 决策

### D1：结构性重构不需要；数据层与接口层需要「先立地基」

2026-07 已完成结构性重构（职责分层、流式编排抽离、协议收窄、常量收敛），
方向正确，191 个测试护航。本轮只做「为扩展铺路」的地基，**不做大爆炸
重构**，不改已验证的性能设计（增量缓冲、倒置列表、贴底判定）。

### D2：数据地基（第一批，纯 Swift，行为不变）

1. `SessionStore` 拆分 `SessionSummary` 与消息分页——消除启动全量物化
   （`load()` 拉取全部消息）与侧栏全量遍历（每行 reduce token）；
2. 消息表派生列：`tokenTotal` / `contentHash` / `indexVersion`
   （GRDB migration，为索引幂等与侧栏聚合铺路）；
3. 流式存储降频 + 后台写队列——消除 O(n²) 写放大与主线程同步写库；
4. `messageStates` LRU 上限——消除准泄漏。

### D3：接口地基（第二批，纯 Swift，协议先行）

1. `IndexEventPublishing`：SessionStore → 索引协调的事件发布协议；
2. `ContextBuilder`：历史截断 / RAG 注入 / 工具结果记账的唯一入口，
   禁止各模块自行拼上下文；
3. `ToolRegistry` / `ToolExecutor` 协议：工具调用循环的契约（实现随
   Tier 2）；
4. `IndexService` / `LibraryIndexService`：Rust 边界的 Swift 契约
   （ADR-0004 D7），UI 永不接触 C 类型。

### D4：SwiftPM target 拆分后置

单 target + 协议先行；多库拆分随 RustCore 落地（Tier 2）时再做，避免为
假想需求引入模块复杂度（延续 ADR-0001 D8 判断）。视图继续依赖具体
`SessionStore` 是既有决策，不翻案；流式 / 索引 / 工具 / 上下文四层必须
协议化。

### D5：Tier 1 验收标准

- 行为不变：`swift test` 全绿（≥191），既有覆盖不降；
- 新增性能基线（XCTMeasure）：启动 1 万条消息、流式存储吞吐、侧栏渲染
  不随消息数线性变慢；
- 依赖方向检查保持单向；
- 每批独立提交、可独立合并、可回滚（沿用 refactor/architecture 纪律）。

## 后果

**正面**：Rust 索引 / RAG / 工具 / 长时推演有干净的数据与接口地基；
功能开发不再回头补数据层。

**代价**：两批地基本身耗时；行为不变约束下收益先以性能基线体现，
用户可见功能延后。

## 备选方案

- 先做功能后补地基：Tier 3~5 每步都要回头改数据层，返工成本更高，否决。
- 现在就拆 SwiftPM target：缺少真实边界需求，增加维护成本，后置到
  RustCore 落地。
