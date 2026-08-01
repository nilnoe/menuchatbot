# DeepSeek Chat 重构路线图（TODO）

> **状态：已完成并归档**（2026-07-31 合并至 main）。本文是历史过程记录，
> 现行架构与测试约定以 [PROJECT_SPEC.md](../PROJECT_SPEC.md) /
> [docs/TESTING.md](TESTING.md) 为准。

> 分支：`refactor/architecture`（从 `main` 3c96aaa 切出）
> 状态：**全部阶段完成**（2026-07-31，质量门三项全过）
> 基线：重构前 `swift test` 140 个测试全部通过；完成后 **146** 个全部通过

本文档是本轮重构的分步计划。每阶段以「小步、行为不变、测试护航」为铁律：
完成一个阶段、跑绿一次，再进入下一阶段，任何阶段都不允许一次性大爆炸重构。

---

## 0. 遵循的项目规范

本计划必须满足 [PROJECT_SPEC.md](../PROJECT_SPEC.md) 与
[CONTRIBUTING.md](../CONTRIBUTING.md) 的全部约定：

1. **复用优先**：不引入新依赖、不自造轮子；重构只动结构不动技术选型。
2. **质量门**（每阶段验收均含）：
   - `swift build` 无警告
   - `swift test` 全绿（重构不降低现有测试覆盖）
   - `swift format lint --recursive --strict Sources Tests` 零违规
3. **行为不变**：流式性能设计（增量缓冲 + 节流）、倒置列表、SQLite 存储、
   导入导出语义、竞态保护等已验证的取舍一律原样保留，只搬位置、不改逻辑。
4. **破坏性变更**：本轮不涉及 schema 变更；若过程中发现需要，必须先走 GRDB
   `DatabaseMigrator` 并单独评估。
5. **文档同步**：改动同步更新本文件、TODO.md、CHANGELOG.md。
6. **提交风格**：按 CONTRIBUTING 使用陈述式提交，重构统一 `refactor: ` 前缀，
   每个阶段独立成提交，便于 review 与回滚。

---

## 1. 遵循的业界实践

本计划不是自由发挥，以下原则是每一步决策的依据：

| 实践 | 出处 / 依据 | 在本项目的落点 |
|---|---|---|
| 小步重构、测试护航 | 《重构》Martin Fowler | 每阶段独立可编译、可测试、可回滚 |
| 单一职责（SRP） | SOLID | 拆掉 `Stores.swift` / `ChatView.swift` 两个「上帝文件」 |
| 依赖规则 | Clean Architecture（Robert C. Martin） | Domain 在最内层，Views 只依赖 Services / Persistence / Streaming |
| Repository 模式 | 企业应用架构模式（Fowler） | `SessionStore` 已是仓储雏形，本轮收口为唯一数据入口 |
| MVVM | SwiftUI 官方数据流模型 | 流式编排从 `ChatView` 抽到 `ChatStreamController`，视图变纯展示 |
| Composition Root | 依赖注入模式 | `AppDelegate` 只负责装配，业务拆分到 Panel / StatusItem / Menu 组件 |
| Strangler Fig | 渐进式改造模式 | 先纯搬移、再抽逻辑、最后改接口，旧代码随阶段自然退场 |
| 测试金字塔 | 《软件测试的艺术》/ 业界共识 | 核心行为单测为主，视图挂窗冒烟保留少量 |
| ADR | 架构决策记录惯例 | `docs/decisions/` 记录关键取舍（目录结构、耦合策略等） |

---

## 2. 现状问题清单

### 2.1 职责混装（内聚问题）

| 文件 | 行数 | 混装职责 | 严重度 |
|---|---|---|---|
| `Stores.swift` | 729 | MessageState（UI 流式状态）、SQLite 记录、SessionStore、SettingsStore、Keychain | ★★★ 上帝文件 |
| `ChatView.swift` | 522 | 滚动测量、贴底判断、流式编排、输入区 UI | ★★★ 视图内嵌业务 |
| `Models.swift` | 140 | 领域模型、API 线格式、UI 展示辅助 | ★★ 三层混装 |
| `MarkdownText.swift` | 233 | 视图组件 + MarkdownCache（非视图逻辑） | ★★ |
| `SettingsView.swift` | 269 | 视图 + `checkConnection()` 网络逻辑 | ★★ |
| `AppDelegate`（在 `DeepSeekChatApp.swift`） | 219 | 生命周期、主菜单、状态栏图标、面板窗口 | ★★ |

### 2.2 耦合问题

- `SessionStore.messageState(for:)` / `syncMessage` 与 `MessageState` 双向耦合
  （这是刻意性能设计，收窄接口而非拆散，见决策点 D1）。
- 测试通过内部 `@State streamingSessionID / streamingState` 驱动流式生命周期
  （`ChatViewRenderTests`），视图一旦重构测试大面积跟着改。
- `com.deepseek.chat` 在 AppLog / KeychainStore / SessionStore 重复出现；
  设置键是散落字符串；`mainPanelV2` 等窗口常量无统一入口。
- `SettingsStore` 保留旧模型名兼容映射（`deepseek-chat` → `deepseek-v4-flash`）
  与仅注释残留的 `saveDelay` 参数，疑似死代码（见决策点 D5）。

---

## 3. 目标架构

SwiftPM 单 target 内按目录分层，依赖方向单向：

```
Views → Streaming → Services / Persistence → Domain
             ↑                    ↑
             └── App（Composition Root，只做装配）
```

```
Sources/DeepSeekChat/
├─ App/
│  ├─ DeepSeekChatApp.swift      @main 入口
│  ├─ AppDelegate.swift          生命周期（瘦身后只做装配）
│  ├─ PanelController.swift      NSPanel 窗口管理（含 PanelSizing）
│  ├─ StatusItemController.swift 状态栏图标 / 右键菜单
│  └─ MainMenuBuilder.swift      主菜单构造
├─ Domain/
│  ├─ Chat.swift                 Role / Source / ChatMessage / ChatSession
│  ├─ SessionExport.swift        SessionExport / SessionImportResult / SessionImportError
│  └─ Effort.swift               Effort（领域值；label 中文文案放 UI 扩展）
├─ Services/
│  ├─ DeepSeekClient.swift       网络层（chatCompletions / responses / validate）
│  ├─ SSEParser.swift            纯函数 SSE 解析
│  ├─ APIMessage.swift           线格式 DTO
│  ├─ ModelCatalog.swift         ModelInfo 能力映射表（供 UI 展示）
│  └─ MarkdownCache.swift        解析缓存（从 MarkdownText 抽出）
├─ Persistence/
│  ├─ SessionStore.swift         仓储：会话/消息 CRUD + 导入导出编排
│  ├─ SessionRecord.swift        GRDB 记录（session / message 两表 + schema）
│  ├─ SettingsStore.swift        设置持久化
│  ├─ KeychainStore.swift        KeychainStoring 协议 + 实现
│  └─ Migration.swift            旧数据迁移
├─ Streaming/
│  ├─ MessageState.swift         可观察消息状态 + 增量缓冲
│  └─ ChatStreamController.swift 流式编排（从 ChatView 抽出）
├─ Views/
│  ├─ ContentView / ChatView / MessageView / SidebarView / SettingsView
│  ├─ MarkdownText.swift         仅视图组件
│  ├─ CodeHighlighter.swift      视图组件（高亮实例化）
│  ├─ SessionFileTransfer.swift  文件面板（AppKit UI 能力，归属 UI 层）
│  └─ DesignTokens.swift
└─ AppConfiguration.swift        统一常量：bundle id / 目录 / 设置键 / 窗口名
```

> 注：`Log.swift` 保持独立（App 级基础设施）；目录划分是组织手段，
> 不改变 SwiftPM target 结构，避免引入模块化复杂度。

---

## 4. 分步计划

### Phase 0：基线锁定（已确认）

- **目标**：建立可复验的回归基线。
- **动作**：
  - [x] `swift test` 140 个测试全绿（2026-07-31 实测，16s）
- [x] `swift build` 无警告确认
- [x] `swift format lint --recursive --strict` 零违规确认
- **验收**：三项质量门结果记录在案，作为后续每阶段的对比基准。
- **风险**：无（只读操作）。

### Phase 1：文件级职责拆分（纯搬移，零行为变化）

- **目标**：消除上帝文件，每个类型独立成文件，不改任何逻辑。
- **动作**：
- [x] 1.1 `Stores.swift` 按职责拆为 6 个文件：
        `Streaming/MessageState.swift`、`Persistence/SessionStore.swift`、
        `Persistence/SessionRecord.swift`、`Persistence/SettingsStore.swift`、
        `Persistence/KeychainStore.swift`（每文件一个提交）
- [x] 1.2 `Models.swift` 拆为：
        `Domain/Chat.swift`、`Domain/SessionExport.swift`、
        `Services/APIMessage.swift`、`Services/ModelCatalog.swift`、
        `Domain/Effort.swift`（label 文案留原处，Phase 2 再挪 UI 扩展）
- [x] 1.3 `MarkdownCache` 从 `MarkdownText.swift` 抽出到 `Services/MarkdownCache.swift`
- [x] 1.4 建 `AppConfiguration.swift` 并收敛 bundle id / 存储目录 /
        设置键 / `mainPanelV2` 等常量（本阶段只建常量表，逐步替换引用）
- **验收**：行为零变化——`git diff` 仅显示文件搬移与 `import` 调整；
  质量门三项全过。
- **风险**：低。纯搬移若出错，测试立即暴露。
- **业界依据**：SRP + 小步重构。

### Phase 2：流式编排抽离（MVVM）

- **目标**：`ChatView` 退化为纯展示；发送/重试/停止/流式循环移出视图。
- **动作**：
- [x] 2.1 新建 `Streaming/ChatStreamController.swift`（`@MainActor`，
        `ObservableObject`），把 `send` / `beginAssistantReply` / `runStream` /
        `retryLastExchange` / `stop` / 40ms flush 循环整体移入
- [x] 2.2 `ChatView` 只保留 UI 绑定（draft、streaming 状态、回调转发），
        滚动逻辑留在视图层（它是纯布局关注点，不属于业务）
- [x] 2.3 `SettingsView.checkConnection()` 抽到
        `SettingsStore` 或独立 `ConnectionChecker`（决策点 D6），视图不再直接 new 网络层
- [x] 2.4 测试迁移：`ChatViewRenderTests` 中依赖内部 `@State` 的用例改为
        面向 `ChatStreamController` 的单元测试；保留少量真实挂窗冒烟
- **验收**：流式竞态保护（旧 Task 收尾不覆盖新任务）行为不变——
  现有 `SessionStoreTests` / `ChatViewRenderTests` 全数通过且不降覆盖；
  `MessageState` 性能基线测试通过。
- **风险**：★ 本轮最大风险点。竞态保护、flush 时序、`streamingState` 归属校验
  必须原样搬迁，禁止顺手"优化"。
- **业界依据**：MVVM + 测试金字塔（行为逻辑单测化）。

### Phase 3：App 层拆分

- **目标**：`AppDelegate` 只做装配，窗口/状态栏/菜单各自成类。
- **动作**：
- [x] 3.1 抽出 `App/PanelController.swift`（NSPanel 生命周期、`PanelSizing`、
        autosave 名称、默认 frame）
- [x] 3.2 抽出 `App/StatusItemController.swift`（状态栏图标、左/右键行为、上下文菜单）
- [x] 3.3 抽出 `App/MainMenuBuilder.swift`（主菜单构造）
- [x] 3.4 `DeepSeekChatApp.swift` 瘦身为入口 + 装配（Composition Root）
- **验收**：质量门三项全过；`PanelSizingTests` 继续通过；
  手动 smoke：呼出/收起面板、右键菜单、编辑快捷键。
- **风险**：低-中。AppKit 生命周期细节（delegate 回调、window resign key）
  搬移时容易丢，依赖现有测试 + 手动冒烟兜底。
- **业界依据**：Composition Root + SRP。

### Phase 4：依赖收窄与接口固化

- **目标**：层间接口明确，为后续扩展（多供应商、Token 统计）留稳定边界。
- **动作**：
- [x] 4.1 按决策点 D1：`SessionStore` 与 `MessageState` 之间引入
        `MessageSynchronizing` 协议收窄写回路径（保留性能设计）
- [x] 4.2 按决策点 D2：评估 `DeepSeekClient` 是否协议化（`APIProviding`），
        决定后记录 ADR
- [x] 4.3 检查并清理 import 依赖方向：Views 不直接 import GRDB / Security /
        Highlighter（这些只属于 Persistence / Services / 视图支撑）
- **验收**：质量门三项全过；`rg` 检查确认依赖方向无回环。
- **风险**：中。协议化可能引入过度抽象，决策点未定前不做。
- **业界依据**：DIP + Repository 模式 + ADR。

### Phase 5：测试体系整理

- **目标**：测试与重构后的结构对齐，核心行为由单测覆盖，视图测试降为冒烟。
- **动作**：
- [x] 5.1 按测试金字塔重组测试文件命名与分组
        （`*StoreTests` / `*StreamControllerTests` / `*ViewRenderTests`）
- [x] 5.2 为 `ChatStreamController` 补齐生命周期单测（发送/停止/重试/竞态）
- [x] 5.3 保留并维护性能基线（`PerformanceBaselineTests`）
- [x] 5.4 删除随重构失效的旧用例，确认总数 ≥ 140
- **验收**：`swift test` 全绿且数量不降；性能基线无回归。
- **风险**：低。
- **业界依据**：测试金字塔。

### Phase 6：文档与收尾

- **目标**：让重构成果可被后人理解和维护。
- **动作**：
- [x] 6.1 更新 `PROJECT_SPEC.md`（第 3 节架构约束：目录结构、层依赖规则）
- [x] 6.2 更新 `TODO.md`（勾选工程项、登记本轮重构）
- [x] 6.3 更新 `CHANGELOG.md`（重构条目，Keep a Changelog 风格）
- [x] 6.4 按决策点 D7 建立 `docs/decisions/` 并记录关键 ADR
- [x] 6.5 更新 README（文件结构小节）
- **验收**：全部文档与实际代码结构一致；质量门三项全过；
  `docs/REFACTORING.md` 全部勾选。
- **风险**：低。
- **业界依据**：ADR + 文档即代码。

---

## 5. 决策点（待拍板，确认后才执行）

| 编号 | 决策（已确认） | 说明 |
|---|---|---|
| D1 | `MessageSynchronizing` + `SessionStoring` 协议收窄 | 写回路径协议化，控制器依赖协议而非具体 store |
| D2 | 网络层暂不协议化 | 回调注入 + MockURLProtocol 已可测，多供应商出现再抽象 |
| D3 | `ChatStreamController` 为 @MainActor ViewModel | 持有 draft / 流式状态，视图纯绑定 |
| D4 | `Effort` 归 Domain，`ModelInfo` 归 Services | label 文案暂留在原文件（体量小不拆分 UI 扩展） |
| D5 | 删 `saveDelay` 残留参数；保留旧模型名映射 | 映射是旧用户数据兼容迁移，非死代码 |
| D6 | `ConnectionChecker` 独立于 SettingsStore | 视图不直接持有网络层 |
| D7 | 建立 `docs/decisions/` ADR | 见 ADR-0001 |
| D8 | 层式目录（layer-based） | 当前体量不适用 feature-based |

---

## 6. 非目标（本轮明确不做）

- 不新增功能、不修 bug（重构途中发现的 bug 记录到 TODO.md，另开分支处理）
- 不引入新依赖、不更换 UI 框架、不做 schema 变更
- 不重写已验证的性能设计（流式缓冲、倒置列表、贴底判定）
- 不做模块化拆分（保持单 target，避免过度工程）
- 不追求一步到位：按 Strangler Fig 渐进推进，任一阶段可独立合并

## 7. 完成定义（Definition of Done）

- [x] 全部 Phase 1–6 勾选完成
- [x] `swift build` 无警告、`swift test` 全绿（≥140）、format lint 零违规
- [x] `rg "com\.deepseek\.chat"` 只剩 `AppConfiguration` 与 Info.plist 单一入口
- [x] Views 目录下无网络 / 存储 / 解析逻辑
- [x] 文档（PROJECT_SPEC / TODO / CHANGELOG / README）与实际结构一致
- [x] PR 描述含结构对比与行为不变声明
