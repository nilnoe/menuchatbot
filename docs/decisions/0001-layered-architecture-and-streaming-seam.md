# ADR-0001：分层架构与流式边界

- 状态：已接受（2026-07-31，refactor/architecture）
- 关联：docs/REFACTORING.md、PROJECT_SPEC.md §3.1

## 背景

重构前 `Stores.swift`（729 行）与 `ChatView.swift`（522 行）混装多种职责，
流式编排内嵌在视图中，测试只能借视图内部 `@State` 驱动。需要在不改变行为
（140 个既有测试为基线）的前提下降低耦合、提高内聚。

## 决策

### D1：流式写回通过协议收窄

`MessageState` 与持久化的写回路径（`syncMessage` / `commitMessage`）抽为
`MessageSynchronizing` 协议；`ChatStreamController` 依赖继承它的
`SessionStoring`（接口隔离），不再直接耦合 `SessionStore` 全部公开 API。
性能设计（增量缓冲 + 40ms 节流 + 按消息粒度观察）原样保留。

### D2：网络层暂不协议化

`DeepSeekClient` 不引入 `APIProviding` 协议。现有回调注入 + MockURLProtocol
已可测；多供应商需求出现时再抽象，避免为假想需求引入抽象层。

### D3：`ChatStreamController` 定位

`@MainActor` ObservableObject 视图模型：持有 draft / streaming 状态，视图只做
绑定。`streamingSessionID / streamingState` 保留内部 set，兼容测试注入完整
流式生命周期。

### D4：模型归属

`Effort` 归 Domain（API 参数域值），中文 label 保留在其文件内（当前体量
不拆分 UI 扩展）；`ModelInfo`（能力映射表）归 Services。

### D5：死代码清理范围

- 删除：`SessionStore.init(saveDelay:)`——SQLite 逐行写入后纯残留，无逻辑使用。
- 保留：`SettingsStore` 旧模型名映射（`deepseek-chat` / `deepseek-reasoner`
  → `deepseek-v4-flash`）——这是旧用户已存数据的**兼容迁移**，删除会造成
  旧设置用户请求失败。
- 保留：`SettingsStore.keychainSaveDelay`——钥匙串防抖写入有实际用途。

### D6：连接测试落点

设置页的 API Key 校验抽为 `ConnectionChecker`（Services 层），视图不直接
持有网络层。

### D7：ADR

建立 `docs/decisions/` 目录记录关键取舍，本文件为第一条。

### D8：目录风格

采用层式（layer-based）目录。当前体量（约 3.5k 行）不适用 feature-based
分组；单一 SwiftPM target，目录只做组织，不引入模块化复杂度。

## 后果

**正面**：上帝文件消失；流式生命周期可单测（含竞态回归）；依赖方向单向
可检查；常量单一入口。

**代价**：分层增加少量间接（协议、目录导航成本）；`ChatViewRenderTests`
等视图测试需随结构同步调整。

## 备选方案

- 完整 Repository / UseCase 协议栈：过度设计，本项目体量不需要。
- 保持 `MessageState` 与 store 原样耦合：写回路径无法独立测试，否决。
- feature-based 目录：多供应商 / 插件化需求出现时再评估。
