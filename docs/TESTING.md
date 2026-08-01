# 测试策略与模块化约定

> 目标：测试代码与生产代码同规模健康演进——目录镜像、按行为面拆分、
> 支持代码接口化。行为基线：模块化前 191 个测试全绿（2026-08-01）。

## 1. 目录约定（镜像 Sources 分层）

`Tests/DeepSeekChatTests/` 下按层分目录，与 `Sources/DeepSeekChat/` 一一对应：

| 目录 | 覆盖 | 典型文件 |
|---|---|---|
| `App/` | 窗口 / 面板 / 应用层 | `PanelSizingTests`、`SettingsWindowSizeTests` |
| `Domain/` | 领域模型与 DTO | `ModelsTests` |
| `Services/` | 网络、解析、缓存 | `DeepSeekClient*`、`SSEParser*`、`MarkdownCacheTests`、`CodeHighlighterTests` |
| `Persistence/` | 存储、迁移、设置 | `SessionStore*`、`SettingsStore*`、`MigrationTests` |
| `Streaming/` | 流式编排与状态 | `ChatStreamControllerTests` |
| `Views/` | 渲染与布局冒烟 | `*RenderTests`、`*LayoutTests` |
| `Performance/` | 性能基线 | `PerformanceBaselineTests` |
| `Support/` | 测试支持 API（mock / harness / 工厂） | `CallbackRecorder`、`*Harness`、`MockURLProtocol` |

规则：

- 文件命名 `<被测类型/行为>Tests.swift`，与源码路径对应
  （`SessionStoreTests.swift` ↔ `SessionStore.swift`）。
- 一个测试类只测一个行为面；单文件接近 300 行时按行为面拆分（见 §2）。
- `Support/` 不包含测试用例，只提供共享能力。

## 2. 按行为面拆分

大测试文件按 MARK 分组拆成 `<类型><行为>Tests` 类，本轮已完成：

| 原文件 | 拆分结果 |
|---|---|
| `SessionStoreTests`（739 行） | CRUD / Message / MessageState / Persistence / ImportExport |
| `DeepSeekClientTests`（518 行） | ValidateAPI / ChatCompletions / Responses |
| `SSEParserTests`（390 行） | Payload / ChatEvent / ResponsesEvent / Helper |
| `SettingsStoreTests`（251 行） | Persistence / Keychain |

拆分守则：只搬位置、不改断言；共享 setUp 一律抽成 Harness（见 §3）；
拆分后跑全量测试，数量不减才算通过。

## 3. 测试支持 API（接口手册）

> 写测试时查本手册即可，不必翻 `Support/` 源码。新增支持能力时同步更新本表
> 并在 `Support/` 内写 `///` 文档注释。

| API | 用途 |
|---|---|
| `CallbackRecorder` | 记录 `StreamCallbacks` 全部回调：`deltas` / `reasoning` / `searchingCount` / `sources` / `usages` / `doneCount` / `errors` |
| `MockKeychain` | 内存 Keychain；`storage` 可预置与断言，`writeCount` / `deleteCount` 可校验写入次数 |
| `MockURLProtocol` | 拦截 URLSession；`handler: (URLRequest) throws -> (HTTPURLResponse, Data)` 返回预设响应 |
| `DelayedStreamingURLProtocol` | 按固定间隔投递分片（响应, 分片, 间隔秒）；用于流式生命周期与竞态测试 |
| `makeMockURLSession()` | XCTestCase 扩展；注入 `MockURLProtocol` 的会话 |
| `makeDelayedStreamingURLSession()` | XCTestCase 扩展；注入延迟流式协议的会话 |
| `httpResponse(_:status:)` | 构造 `HTTPURLResponse` |
| `httpBody(of:)` | 读取请求体（兼容 `httpBody` / `httpBodyStream` 两种形态） |
| `SessionStoreHarness` | 每个用例独立临时目录；`makeStore()` 即「跨实例重载」、`writeFile(_:_:)` 构造旧版文件、`cleanup()` 清理 |
| `SettingsStoreHarness` | 隔离的 UserDefaults 套件 + `mockKeychain`；`makeStore(keychain:saveDelay:)`、`cleanup()` |
| `AuditRecorderSink` | 线程安全的事件记录 sink（兼作 `AuditLogging`）；`events(domain:category:)` 过滤、`clear()` 分段清空；配合 `makeAuditLogger(sinks:)` 与 `flushSync()` 做断言（AU-9 等） |

约定：

- 所有 URLProtocol mock 的 handler 在 `tearDown` 中置 nil，防止用例间串扰。
- 新共享能力放 `Support/`，禁止复制进各测试文件；有需要就进 Harness。

## 4. 测试分层与运行

- 金字塔：单测为主（Domain / Services / Persistence / Streaming），
  视图渲染 / 布局冒烟保持少量，性能基线独立成目录。
- 全量：`swift test`
- 按类过滤：`swift test --filter SessionStoreCRUDTests`
- 性能基线：只随性能相关改动更新，不在功能迭代中膨胀。
- CI：lint + 全量测试（见 `.github/workflows/ci.yml`）。

## 5. 新增测试流程

1. 按 §1 找到被测类型对应的目录与文件（没有则按约定新建）。
2. 需要共享 mock / 工厂：先查 §3 手册，没有才在 `Support/` 新增并登记。
3. 一个行为面一个测试类；断言带失败原因（`XCTAssert(..., "原因")`）。
4. 过质量门：`swift test` 全绿 + `swift-format lint --recursive --strict Sources Tests` 零违规。

## 6. 质量门

与 [CONTRIBUTING.md](../CONTRIBUTING.md) 一致：

- `swift build` 无警告
- `swift test` 全绿（重构不得降低测试数量）
- `swift-format lint --recursive --strict Sources Tests` 零违规

## 7. 未来演进（Plan B）

当单 test target 继续膨胀、或 CI 需要分层 / 分片时，升级为多测试 target：

- 拆 `CoreTests` / `ViewTests` / `PerformanceTests` + 独立 `TestSupport` 模块；
- 届时 §3 的 API 清单就是 `public` 化的候选清单，接口由编译器强制；
- 建议触发条件：全量测试超过约 5 分钟，或单 target 测试文件超过约 60 个。
  触发前保持单 target，不为假想规模引入复杂度。

完整的分阶段规划（Phase A 已完成、B / C 的步骤与触发条件）见
[TESTING_ROADMAP.md](TESTING_ROADMAP.md)。
