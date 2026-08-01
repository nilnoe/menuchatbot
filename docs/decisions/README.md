# 架构决策记录（ADR）索引

本项目用 ADR 记录关键架构取舍。新记录编号递增，正文结构固定为
「背景 → 决策（D1/D2…）→ 后果 → 备选方案」，头部注明状态、日期与关联。

| ADR | 主题 | 状态 | 关联 |
|---|---|---|---|
| [0001](0001-layered-architecture-and-streaming-seam.md) | 分层架构与流式边界 | 已接受（2026-07-31） | [REFACTORING](../REFACTORING.md) |
| [0002](0002-custom-model-provider.md) | 自定义模型供应商 | 已接受（2026-07-31） | TODO「Beta 0.3」 |
| [0003](0003-test-modularization.md) | 测试代码模块化 | 已接受（2026-08-01） | [TESTING_ROADMAP](../TESTING_ROADMAP.md) |
| [0004](0004-rust-core-index-engine.md) | Rust 核心集成（静态库 + C ABI） | 已接受（2026-08-01，方向定稿） | [DESIGN_RUST_CORE](../DESIGN_RUST_CORE.md) |
| [0005](0005-local-library-rag.md) | 本地资料库 RAG | 已接受（2026-08-01，方向定稿） | TODO「Rust 核心与 AI 能力规划」 |
| [0006](0006-mcp-tool-host.md) | MCP 兼容本地工具宿主 | 已接受（2026-08-01，方向定稿） | TODO「Rust 核心与 AI 能力规划」 |
| [0007](0007-extended-deliberation.md) | 长时推演模式 | 已接受（2026-08-01，方向定稿） | TODO「Rust 核心与 AI 能力规划」 |
| [0008](0008-refactor-assessment.md) | 重构评估与执行顺序（数据瓶颈 + 接口边界） | 已接受（2026-08-01） | TODO Tier 1 |
