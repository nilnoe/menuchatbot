# DeepSeek Chat 工程规范

> 本文档是 DeepSeek Chat 的工程规范，所有代码与改动必须遵守。
> 版本状态：Beta 0.3 · 纯 Swift / SwiftUI 原生 macOS 菜单栏应用。

---

## 1. 核心工程原则

> **尽可能复用开源库的代码，不要自己造轮子。**

这是本项目的第一工程原则，优先级高于其他一切开发偏好：

1. **先找库，再写代码。** 任何新功能落地前，先搜索是否有成熟的开源库或系统框架
   已经覆盖该能力；有就接入，没有才允许自研，并且自研部分必须注释说明"为什么不用库"。
2. **复用系统框架优先。** SwiftUI / AppKit / Foundation / Security 等系统能力
   一律直接使用，绝不重复实现（例如 Keychain 用 `Security`，不要自写加密存储）。
3. **复用已接入的库。** 已接入的 MarkdownUI、GRDB 能满足的需求，不得另引新依赖或自研。
4. **解析、网络、存储、渲染、格式处理等通用能力禁止自研。**
   例如：Markdown 解析用 MarkdownUI / swift-markdown；数据库用 GRDB；SSE / JSON 解码
   优先使用库或标准库能力。
5. **依赖必须可维护。** 新依赖要求：许可证友好（MIT / Apache-2.0 等）、有维护记录、
   纯原生优先（避免 WebView / 运行时服务进程）、体积与性能可接受。
6. **记录取舍。** 引入依赖在 `Package.swift` 与 CHANGELOG 中记录；拒绝某库而自研时，
   在代码注释中写明原因，方便后人复评。

### 禁止"造轮子"清单

| 能力 | 已复用方案 | 禁止 |
|---|---|---|
| Markdown 解析 / 渲染 | `MarkdownUI`（gonzalezreal/MarkdownUI） | 自写 Markdown 解析器 |
| 会话持久化 | `GRDB`（groue/GRDB.swift，SQLite） | 自写数据库层 / 手写文件锁 |
| 代码高亮 | `MarkdownUI.CodeSyntaxHighlighter` 协议 + 开源高亮库（如 Splash） | 自写分词器 |
| 密钥存储 | macOS `Security`（Keychain） | 自写加密存储 |
| HTTP / SSE 网络 | `URLSession` + 标准库 | 自写 TCP 层 |
| UI | SwiftUI / AppKit 原生控件 | 自绘基础控件 |

---

## 2. 技术栈

- 语言 / 平台：Swift 5.9+，macOS 14+（Apple Silicon / Intel）
- UI：SwiftUI（菜单栏 / 面板用 AppKit `NSStatusItem` + `NSPanel` 承载）
- 持久化：GRDB 6（SQLite，WAL 模式），FTS5 预留全文搜索
- Markdown：MarkdownUI 2.x（swift-markdown 解析）
- 构建：SwiftPM，`scripts/make-app.sh` 打包 .app 并本地签名

## 3. 架构约束

- **纯原生**：不引入 Web 框架、WebView、运行时服务进程。
- **UI 与网络解耦**：`DeepSeekClient` 只负责 API 调用与回调；
  `SSEParser` 保持纯函数、可单测；视图不直接持有网络层。
- **流式性能**：流式回复必须走 `MessageState` 增量缓冲 + 节流提交，
  禁止"每 token 触发整树重算 / 全文重解析"。
- **存储**：所有会话读写经 `SessionStore`（GRDB 队列），UI 不直接碰 SQL。
- **隐私底线**：API Key 只存钥匙串；会话数据默认不离开本机。

### 3.1 目录分层（2026-07 重构后）

源码按职责分层组织（SwiftPM 单 target，目录是组织手段），依赖方向单向：

```
Views → Streaming → Services / Persistence → Domain
             ↑                    ↑
             └── App（Composition Root，只做装配）
```

```
Sources/DeepSeekChat/
├─ App/          入口（@main）、AppDelegate 装配、PanelController、
│                StatusItemController、MainMenuBuilder
├─ Domain/       领域模型：ChatMessage / ChatSession / Role / Source、
│                导入导出 DTO、Effort 枚举、CustomModel（自定义供应商模型）
├─ Services/     网络层（DeepSeekClient / SSEParser / APIMessage）、
│                ModelCatalog（内置 + 自定义模型目录）、MarkdownCache、
│                ConnectionChecker
├─ Persistence/  SessionStore（仓储）、GRDB 记录、SettingsStore、
│                KeychainStore、旧数据迁移
├─ Streaming/    MessageState（可观察流式状态 + 增量缓冲）、
│                ChatStreamController（流式编排）、SessionStoring 协议
├─ Views/        纯视图 + 视图支撑（DesignTokens / CodeHighlighter /
│                SessionFileTransfer 等 AppKit 文件面板能力）
└─ AppConfiguration.swift  应用级常量单一入口
```

分层规则：

1. **依赖方向**：Views 可依赖任意下层；Streaming 可依赖 Services /
   Persistence / Domain；Services、Persistence 只能依赖 Domain；
   Domain 不依赖任何上层；App 只做装配。
2. **接口隔离**：流式编排只依赖 `SessionStoring` 协议（继承
   `MessageSynchronizing`），不直接耦合 `SessionStore` 全部公开 API；
   视图仍直接使用具体 store。
3. **视图纯净**：View 文件不得包含网络、存储、解析逻辑；业务编排在
   `ChatStreamController` / Store 层。
4. **例外**：`Views/CodeHighlighter.swift` 引入 Highlighter 属视图层渲染
   适配器（MarkdownUI `CodeSyntaxHighlighter` 实现），是刻意保留的例外。

## 4. 代码与测试规范

- Swift 命名遵循 Swift API Design Guidelines；public 符号必须有文档注释。
- 新增逻辑必须配单测；纯函数（解析 / 序列化 / 状态机）优先做成可单测形态。
- 测试代码按层组织，镜像 `Sources/` 分层；目录约定、命名规范与支持 API
  手册见 [docs/TESTING.md](docs/TESTING.md)，模块化规划见
  [docs/TESTING_ROADMAP.md](docs/TESTING_ROADMAP.md)。
- 任何破坏性 schema 变更必须走 GRDB `DatabaseMigrator` 迁移，禁止直接改表删表。
- 性能敏感路径（渲染、滚动、存储）在 PR 描述中说明复杂度，并尽量用 XCTMeasure 防回归。
- 改动同步更新 CHANGELOG.md / TODO.md 及受影响文档（README、docs/ 下指南）；
  新增共享测试能力时登记 docs/TESTING.md 支持 API 手册。

## 5. 引入新依赖的流程

1. 搜索确认没有更合适的既有库或系统能力（记录搜索词）。
2. 评估许可证、维护状态、平台要求（macOS 14+、纯原生、SwiftPM 可集成）。
3. 加入 `Package.swift` 并锁定版本；`Package.resolved` 入库。
4. 在 CHANGELOG 记录引入原因；如属重大依赖，更新本文件"禁止清单"。

## 6. 发布与流程

- 版本：Beta → 1.0 前按 TODO 路线图推进；每次发布更新 CHANGELOG 与 README。
- 构建：`./scripts/make-app.sh` 产出 `dist/DeepSeek Chat.app`。
- 质量门：`swift build` 无警告、`swift test` 全绿、
  `swift-format lint --recursive --strict Sources Tests` 零违规、
  `./scripts/check-scale.sh` 通过（规模与单文件大小上限，阈值见脚本头部）。
- CI：GitHub Actions 已接入（lint / test / release 三 job，见
  `.github/workflows/ci.yml`）；格式统一 swift-format（SwiftLint 未引入）。
