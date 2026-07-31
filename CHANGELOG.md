# 版本更迭

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格记录各版本变化。

## [Unreleased]

### 新增

- **Token 用量展示与费用估算（Beta 0.3）**
  - 流式请求自动携带 `stream_options.include_usage`，从 Chat Completions 收尾块 /
    Responses `response.completed` 解析 token 用量（含缓存命中分项），按消息持久化
    （GRDB `message.usageJSON` 列，v2 迁移自动升级旧库）。
  - assistant 消息气泡下方显示「输入 / 输出 / 缓存命中」用量与费用估算；
    侧栏会话行显示累计 tokens。
  - 费用按 DeepSeek 官方单价（USD / 1M tokens，含缓存命中/未命中分价）估算，
    单价收敛在 `ModelCatalog`，自定义模型价格未知时不估算。
  - 测试从 158 增至 171（SSE 用量解析、请求参数、成本估算、持久化、旧库迁移、
    流式端到端）。

- **侧栏 hover 快捷操作与会话图标（Beta 0.2 收尾）**
  - 侧栏会话行 hover 时浮现重命名 / 删除按钮（带 help 提示与淡入动画），
    与右键菜单行为一致；删除后选中项回退到剩余会话。
  - 会话行增加图标：普通会话为气泡，最近消息带参考来源（联网搜索过）的
    会话用地球图标区分，选中时着强调色。
  - 新增 `SidebarViewRenderTests` 挂窗渲染冒烟（覆盖两种图标路径），
    测试从 157 增至 158。

- **自定义模型供应商（Beta 0.3 起点）**
  - 设置页新增「自定义模型供应商」分区：可启用 OpenAI 兼容供应商、配置 API
    Base URL（默认回退 `https://api.deepseek.com`）与自定义模型列表（模型 ID +
    显示名，可增删）。
  - 启用后请求自动发往自定义地址（`{base}/chat/completions`、`{base}/models`），
    模型选择器合并展示自定义模型，消息气泡标签用配置的显示名。
  - 自定义模型按 OpenAI 兼容 Chat Completions 处理：请求体只含标准字段，
    自动省略 DeepSeek 专属参数（`thinking` / `reasoning_effort`），并禁用思考
    模式与联网搜索（Responses API 为 DeepSeek 专属能力）。
  - 关闭供应商或删除当前选中的自定义模型时，选中项自动回退内置模型，
    避免拿自定义模型 ID 请求官方接口。
  - 设置页「测试连接」按当前生效地址校验 Key（`GET /models`）。
  - 取舍记录：见 `docs/decisions/0002-custom-model-provider.md`（沿用 ADR D2
    结论，网络层不做全量协议化，仅参数化 baseURL + 能力标记）。

### 重构（refactor/architecture）

按 [docs/REFACTORING.md](docs/REFACTORING.md) 完成分层架构重构，行为零变化：

- **文件级拆分**：`Stores.swift`（729 行）按职责拆为 Streaming / Persistence
  六个文件；`Models.swift` 拆为 Domain / Services 五层；`MarkdownCache`
  从视图文件抽出到 Services。
- **流式编排抽离（MVVM）**：`ChatView`（522 行）中的发送 / 重试 / 停止 /
  流式循环整体迁入 `ChatStreamController`（`@MainActor` ObservableObject），
  视图退化为纯展示；设置页连接测试抽为 `ConnectionChecker`。
- **App 层拆分**：`AppDelegate` 瘦身为 Composition Root，拆出
  `PanelController` / `StatusItemController` / `MainMenuBuilder`。
- **依赖收窄**：新增 `SessionStoring`（继承 `MessageSynchronizing`）协议，
  流式编排只依赖该协议，便于测试注入与替换实现。
- **常量收敛**：新增 `AppConfiguration` 统一 bundle id、存储目录、设置键、
  面板 autosave 名称；移除 `SessionStore` 残留的 `saveDelay` 参数。
- **测试**：新增 `ChatStreamControllerTests`（发送 / 复用会话 / 重试 / 停止 /
  错误 / 旧任务延迟收尾竞态回归），测试从 140 增至 146。

> 关键取舍记录见 `docs/decisions/`（ADR）。

## [0.2.0] - 2026-07-31

### 里程碑

Beta 0.2：完成 TODO 中第一节全部 P0 性能优化与存储演进，长会话 / 长输出流式不再卡顿、不再空白。

### 新增

- **流式性能（P0）**
  - 每条消息独立 `MessageState`（ObservableObject）：分片只刷新当前消息行，会话列表只观察元数据，删除「每分片全树重算」。
  - 分片聚合：增量先进缓冲，40ms 窗口一次性提交 UI 与存储（约 25fps），避免每 token 对全文重排。
  - 实时 Markdown：流式过程中即渲染（约 4fps 节流），结束后再按最终内容精确渲染一次；解析结果按内容缓存复用。
  - 超长消息保护：单条超过 2 万字默认截断 +「展开全部」。
- **存储演进（P2）**
  - 会话持久化从「整库 JSON 编码 + 防抖落盘」迁移到 SQLite（GRDB 6.29 + WAL）：`session` / `message` 两表、逐行即时写入，长会话不再全量序列化。
  - 旧版 `sessions.json` / `state.json` 启动时自动一次性迁入（仅当库为空），原文件保留不删。
- **Markdown 渲染复用开源库**
  - 接入 MarkdownUI 2.4.1（内部 swift-cmark），替换自研 `AttributedString(markdown:)` 解析，获得表格与 GFM 支持。
- **聊天列表改为倒置布局（inverted ScrollView）**
  - 解决「长输出后第二轮发送，消息区空白、滑动才显现」：LazyVStack 程序化滚动到未物化区域会渲染空白；倒置列表让新消息天然落在底部、滚动目标永远是相邻已物化的一行，同时保留懒加载。
- **联网搜索参考来源 URL 安全化**：移除 `URL(string:)!` 强制解包崩溃隐患。

### 修复

- 流式任务收尾竞态：停止后旧任务延迟收尾会覆盖新一轮流式的状态，导致新回复失去流式标记、长输出走最终 Markdown 路径逐分片全文解析而卡死；收尾前校验状态归属，并为消息增加自身 `isStreaming` 标记兜底。
- 底部跟随仅发生在用户贴底时；流式期间即时滚动并节流到 12 次/秒，不抢用户上翻阅读位置。
- 旧版切换会话 / 新建会话的滚动行为保持一致。

### 工程

- 新增依赖：MarkdownUI 2.4.1、GRDB.swift 6.29.3。
- 测试从 81 增至 100，新增：SQLite 持久化 / 顺序 / 级联删除、两轮对话一致性、消息流式生命周期、Markdown 缓存、真实视图挂窗渲染冒烟（ChatView 级别两轮渲染 + 滚动越界校验）。

## [0.2.1] - 2026-07-31

### 新增

- **设置：System Prompt 与 temperature**
  - 可自定义系统提示词（随每次请求发送，留空用模型默认）；temperature 0~2 可调，关闭后跟随模型默认、不随请求发送。
  - Chat Completions 通过 system 消息 / `temperature` 字段传递；Responses API 通过 `instructions` / `temperature` 传递。
- **代码高亮（复用开源库）**
  - 接入 HighlighterSwift 3.1（内部 highlight.js 11，185+ 语言 + 自动检测），通过 MarkdownUI 官方 `CodeSyntaxHighlighter` 协议渲染，未自写任何分词器。
  - 明暗模式各自主题（atom-one-dark / atom-one-light），代码统一 SF Mono。
  - 高亮结果按（语言, 内容）缓存、超长代码块（>10 万字）自动跳过高亮；流式期间走纯文本高亮器，避免每 250ms 全文重跑 JS。
- **会话导入 / 导出（JSON）**
  - 设置页「数据」区：导出全部会话为 JSON 备份 / 从备份导入恢复；侧边栏右键可导出单个会话。
  - 备份带格式标识与版本号（`deepseek-chat-sessions` v1），解码或校验失败整体回滚，不产生部分导入。
  - 导入自动重新生成会话与消息 UUID，追加到现有数据、绝不覆盖；文件面板复用系统 NSSavePanel / NSOpenPanel。
- **工程规范**
  - 新增 `PROJECT_SPEC.md`：核心原则「尽可能复用开源库的代码，不要自己造轮子」，含禁止造轮子清单与依赖准入流程。
- **工程加固**
  - CI：GitHub Actions（macOS 14）跑 `swift build` + `swift test` + swift-format lint；打 `v*` tag 时自动 release 构建并上传 .app 产物。
  - 代码规范：接入 `swift-format`（随 Xcode 工具链自带，零新依赖）+ `.swift-format` 配置 + `.editorconfig`；全仓库格式化后 lint 零违规。
  - 性能基线：新增 `PerformanceBaselineTests`（XCTMeasure），覆盖 Markdown 解析、SSE 解析、流式分片聚合三条关键路径，防回归。
  - 日志：NSLog 全部替换为系统统一日志（`os_log`，subsystem `com.deepseek.chat`），Console.app / `log stream` 可查。
  - 协作与发布：CONTRIBUTING.md、Issue/PR 模板、docs/RELEASING.md（版本号、打 tag、产物上传、正式版签名公证路径）。

### 工程

- 新增依赖：HighlighterSwift 3.1.0（MIT；highlight.js BSD-3-Clause）。
- 测试从 100 增至 123：设置持久化（systemPrompt / temperature）、请求体参数（system 消息 / instructions / temperature）、高亮引擎（Swift 高亮、自动检测、缓存、超长跳过、主题回退）、代码块挂窗渲染冒烟、导入导出（往返、ID 去重、跨实例持久化、单会话导出、空库、格式 / 版本 / 非法 JSON 拒绝、失败回滚）、性能基线（Markdown / SSE / 流式聚合）。

## [0.2.2] - 2026-07-31

### 新增（排版规范 + 消息区/输入区美化）

- **设计 token**：字号梯度（caption/callout/body）、行高 1.5、4pt 间距网格、圆角（6/10/14）、品牌蓝紫渐变统一入口，消除散落魔法数字。
- **消息列居中**：大窗口下内容限制 780pt 居中，不再满屏拉长。
- **消息区美化**
  - 用户消息带头像；assistant 消息带模型标签（V4 Flash / V4 Pro）。
  - 消息时间戳（HH:mm）轻量展示；气泡淡入 + 上移动画。
  - 气泡宽度与文字长短协调：修复气泡被撑满整行的问题——短文本贴合文字、长文本在限宽内换行（用户气泡上限 520pt、assistant 720pt）。
  - 右键菜单复制纯文本 / Markdown 源码（纯文本提取复用系统 `AttributedString(markdown:)`）。
  - 错误消息红色弱化 + 重试按钮：删除末尾错误回复、重新生成最后一条用户消息的回答（新增 `SessionStore.removeMessage`，删除后重排 position）。
  - 思考过程折叠面板渐变底；参考来源卡片化（标题 + 域名 + 外链图标）。
- **代码块卡片**：MarkdownUI 官方 `codeBlock` 扩展点实现语言标签 + 复制按钮，正文仍是开源高亮引擎渲染。
- **中文排版**：聊天 Markdown 主题调整标题层级、段落与引用块间距。
- **输入区 / 侧栏 / 空状态**
  - 输入框聚焦高亮描边；发送按钮状态不变。
  - 侧栏按「今天 / 昨天 / 更早」分组。
  - 空状态建议提问 chips，点击即发送。
- **统一系统表面风格**：不叠加整窗毛玻璃——参考 ChatGPTUI / Messages 类开源聊天应用的惯例，
  采用「系统底色 + 纯色组件」：侧边栏 / 输入框用系统标准色，用户气泡纯强调色、assistant 气泡系统控件色，
  全界面统一 10pt 圆角与发丝描边，避免窗口材质与组件材质叠加造成的风格割裂。
  （整窗毛玻璃暂缓，待全组件材质一致化后再做。）
- **倒置列表观感**：隐藏镜像滚动条（倒置布局下滚动条方向相反、位置在左侧），更贴近聊天应用惯例；
  倒置布局本身是为绕开「LazyVStack 程序化滚动到未物化区域 → 空白」缺陷而保留的取舍。
  **短会话顶置**：利用「旋转前底部 = 旋转后顶部」给内容加 `minHeight(视口高)`，
  首条气泡顶到视口顶部、逐条向下增长（视觉上就是正序文档）；内容超过视口后自动回到贴底跟随。
- **默认窗口更大**：从可见区域的 75% 提升到 93%（铺满但四周留边距），视觉更舒展；
  窗口 autosave 名称升级为 `mainPanelV2`，旧的小窗口尺寸作废一次，用户重调后仍会被记住。
  大窗口下消息列仍限宽 780pt 居中（类 Slack/Discord 阅读列），气泡宽度上限不变。
- **设置页收尾**
  - 卡片化分组：系统 grouped 表单 + 滚动兜底，小窗口下内容不再被裁切。
  - API Key 显示 / 隐藏切换（眼睛按钮），粘贴 / 核对更方便。
  - 「测试连接」按钮：调 `GET /models` 验证 Key（新增 `DeepSeekClient.validateAPIKey()`，
    复用现有错误解析，不写新解析逻辑），成功显示可用模型数、失败显示具体原因；
    Key 修改后旧的连接结果自动失效。

### 工程

- 测试从 123 增至 140：`removeMessage` 内存 / 跨实例持久化 / 未知 ID、排版后消息形态挂窗渲染冒烟、气泡宽度布局回归（短文本贴合 / 长文本限宽换行）、倒置列表布局回归（短会话顶置 / 长会话贴底 / 顺序恒正序）、真实 ChatView 短会话墨水分布（上半墨水 > 下半）、窗口默认尺寸（93% 铺满且居中）、Key 校验（成功 / 401 拒绝 / 网络错误）、设置页挂窗渲染冒烟。
- 版本号升至 0.2.2（`scripts/make-app.sh` Info.plist 同步）。

> 注：0.2.2 的视觉改动建议真机目检明暗两套外观；CI 只保证可构建可测试。

## [0.1.0] - 2026-07-31

- 初始版本：原生 macOS 菜单栏 AI 聊天应用（Beta 0.1）。
- 菜单栏常驻、流式回复、思考模式、联网搜索、多会话管理、钥匙串 API Key 存储、Markdown 渲染、窗口位置记忆。

---

# 开发经验（踩坑记录）

这轮迭代踩过的坑与最终验证过的方法，供后续开发参考。

## 1. `@Published` 对数组的就地修改也会逐字段发布

`@Published var sessions: [ChatSession]` 下，`sessions[i].messages[j].content = x` 这类就地元素修改**同样会触发 objectWillChange**（每个字段一次）。最初实现「流式静默写回存储」时因此白做了假设，测试计数（6 次发布 = 5 字段 + updatedAt）才暴露。

**结论**：需要「写回但不刷新 UI」时，把 setter 改为 `private(set)` 并显式控制 `objectWillChange.send()`；`@Published` 只留给真正需要自动发布的值。

## 2. Swift String 写时复制 + 写回共享缓冲 = 隐藏的 O(n²)

`state.content += chunk` 本身是均摊 O(1)；但一旦把 `state.content` 复制给存储（两个引用共享同一缓冲区），下一次追加就会触发整块 CoW 拷贝，每分片一次全文复制，长回复退化成 O(n²)。

**结论**：流式写回不要逐分片做；配合聚合窗口（40ms）把写回频率压到固定值，CoW 摊薄到可忽略。

## 3. 每 token 一次全文重排

## 4. SwiftUI `.frame(maxWidth:)` 的两种反直觉行为

- 放在 **HStack + Spacer 里的气泡**上：贪婪扩展到 maxWidth，短文本也撑满整行 → 气泡过长。
- 放在 **VStack 内层**包内容：理想宽度为 0，容器直接塌陷。

**结论**：聊天气泡要「贴合文字 + 限宽换行」，用**行级限宽**——限制整行宽度，气泡在行内自然贴合。
行为用 GeometryReader 探针实测验证（`BubbleLayoutTests` 固化该规则），不要凭直觉改布局。

即使每消息有独立 ViewModel，分片直接追加仍会让 SwiftUI `Text` 对累积全文重新排版。

**结论**：增量先进 pending 缓冲，按固定时间窗口（30~60ms）聚合提交 UI。这是所有流式聊天客户端的通用做法。

## 4. LazyVStack 程序化滚动到未物化区域 = 空白

长内容下 `proxy.scrollTo("bottom")` 的目标可能从未被 LazyVStack 物化，滚动落点渲染成空白，且**只有用户手动滚动才触发物化**（Apple 论坛 741406 同款问题）。

试过的错误方案：

- 把底部锚点挪出 LazyVStack 常驻物化：目标有效了，但**视口里仍是未物化的消息行**，空白依旧。
- 把最后几条消息移出 LazyVStack 用外层 VStack 常驻：空白解决，但 **VStack 需要 LazyVStack 的完整高度 → 懒加载被杀死**，每次分片刷新 260ms、每次 resize 330ms（基准实测），全应用卡顿。

**最终方案**：倒置聊天列表（inverted ScrollView）——`ForEach(messages.reversed())`，容器与每行各旋转 180°（双重旋转让文本/选区恢复正向）。新消息天然落在视觉底部，「滚动到底」变成滚动到相邻且必然已物化的一行，LazyVStack 保持直接子级、懒加载完好。

## 5. 旧 Task 收尾覆盖新一轮流式状态（竞态）

`stop()` 取消任务后，任务要等网络栈把取消传播完才继续执行收尾代码；若用户紧接着发送新消息，旧任务的收尾会把新任务的 `streamingSessionID / streamingState` 清成 nil，新回复失去流式标记，长输出按最终路径每分片全文解析 → 卡死。

**结论**：异步任务收尾写共享状态前，先校验状态仍属于自己（如 `streamingState === 本次 state`）；再给消息自身维护 `isStreaming` 标记兜底，行内渲染不依赖可能被覆盖的外部状态。

## 6. 验证方法论

- **真实视图挂窗渲染测试**：把完整 ChatView 挂进 `NSHostingView` + `NSWindow`，强制布局后 `cacheDisplay` 截图，用「非背景像素占比」判断消息区是否空白；强制浅色外观让指标有效（深色模式下空白背景也是深色，指标失真）。
- **系统日志取证**：`/usr/bin/log show --predicate 'process == "DeepSeekChat"'` 配合数据库更新时间，能还原用户操作时序（如 -999 取消流与复现时刻吻合）。
- **对照实验**：怀疑某改动导致回归时，临时还原旧实现跑同一测试/基准，确认测试真的能抓到问题，再恢复修复。
- **基准先行**：性能回归用可量化的布局耗时对比（流式 flush / resize 毫秒数），不要靠感觉。
