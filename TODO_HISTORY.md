# DeepSeek Chat 开发路线图（历史归档 TODO_HISTORY）

> 版本状态：Beta 0.3（2026-08-01，同日拆分归档）
> 本文档是**历史归档与低优先级 backlog**：原 TODO.md 一~五节（性能记录 /
> UI 改进 / 功能路线图 / 工程记录 / 长期探索）拆分至此。
> 现行规划以 [TODO.md](TODO.md) 为准；本文件条目不再随现状改写，
> 需要重启某项时先评估、再捞回 TODO.md。

---

## 一、已知问题：长会话卡顿（性能）

### 根因分析

当前流式回复时，每次收到一个 token 分片都会触发整棵视图树重算，工作量随会话长度**平方级**增长：

1. **全量重渲染**
   `SessionStore.updateMessage()` 每次分片都调用 `objectWillChange.send()`，而 ChatView / SidebarView 都观察整个 `sessions` 数组 → 每次 delta 全会话重算。会话越长越卡。
   - 涉及：`Persistence/SessionStore.swift`、`Streaming/MessageState.swift`、
     `Views/ChatView.swift`

2. **Markdown 每次重解析**
   `MarkdownText` 的 `attributedString` 是计算属性，每帧都对**完整消息内容**执行 `AttributedString(markdown:)`。流式时每条分片重解析一次累积全文 → 单条长消息 O(n²)。
   - 涉及：`Views/MarkdownText.swift`

3. **每条分片都触发滚动动画**
   `onChange(of: last.content)` 每次分片都执行 `withAnimation + scrollTo`，并且没有"用户上翻时不要抢滚"的判断。
   - 涉及：`Views/ChatView.swift`

4. **单行超长消息渲染**
   一条消息数万字符时，`Text`/`textSelection(.enabled)` 单行渲染本身开销很大，缺少虚拟化与截断策略。
   - 涉及：`Views/MessageView.swift`

### 改进方案（按优先级）

- [x] **P0 流式更新只刷新当前消息行**
  为每条消息建立独立 ViewModel（`MessageState`，ObservableObject），流式分片只更新该消息的状态；会话列表只观察元数据。删除"每分片全树重算"。
  - 验收标准：200 条消息、单条 5 万字会话中流式输出仍流畅；用 Instruments Time Profiler 对比修复前后
- [x] **P0 Markdown 缓存 / 流式期间实时渲染**
  流式过程中实时渲染 Markdown，但按 ~250ms 节流（约 4fps），避免每个 token 都对累积全文重新解析/排版；最终解析结果按内容缓存复用。
- [x] **P0 滚动策略**
  检测用户是否在底部：仅在底部时自动滚动；流式期间用即时滚动（无动画）并节流到 12 次/秒。
  （实现说明：macOS 14 的 `.scrollPosition(id:)` 只上报顶部锚定视图的 ID，无法可靠判断“贴底”，故用顶部偏移 + 底部锚点 + 视口高度三个 GeometryReader 测量值判定，逻辑可测、无版本歧义。）
- [x] **P1 分片节流**
  将分片以 40ms 窗口聚合后再刷新 UI，减少 SwiftUI diff 次数（对超长回复收益明显）。
- [x] **P1 超长消息保护**
  单条消息超过 2 万字时默认截断显示 +「展开全部」（超长会话的“最近 N 条”虚拟化由 LazyVStack 承担）。
- [x] **P2 存储演进（SQLite / GRDB）**
  已从「会话 JSON 全量读写」迁移到 SQLite（GRDB 6）：`session` / `message` 两表、逐行写入、WAL 模式；
  旧 `sessions.json` / `state.json` 在启动时一次性迁入（仅当库为空），原文件保留不删除。为全文搜索（FTS5）与超长历史做铺垫。

---

## 二、UI / 排版改进

### 视觉与窗口

- [ ] 面板毛玻璃：暂缓（0.2.2 先采用「系统底色 + 纯色组件」统一表面；若后续做毛玻璃，需先统一全部组件材质再叠加窗口材质）
- [x] 明暗模式与系统强调色适配；品牌色（DeepSeek 蓝紫渐变）只用于头像 / 点缀
- [x] 消息列居中且随主区等比缩放：对话列占主区宽度 86%（两侧各 7% 空隙），
  用户 / assistant 气泡按列宽 66% / 92% 等比缩放；窗口调整时「对话与主区」
  比例不变（0.3 起替换固定 780 / 520 / 720 设计）

### 排版规范

- [x] 建立设计 token：字号梯度（caption/callout/body）、行高 1.5、间距（4/8/12/16）、圆角（6/10/14）
- [x] 代码统一使用 SF Mono，代码块卡片样式（语言标签 + 复制按钮）
- [x] 中文排版优化：标题与正文层级、段落/引用块间距（Markdown 主题）

### 消息区

- [x] 消息时间戳（轻量显示 HH:mm）
- [x] 用户消息带头像；assistant 消息带模型标签（V4 Flash / V4 Pro）
- [x] 气泡出现动画（淡入 + 轻微上移）
- [x] 消息操作：右键复制（纯文本 / Markdown 源码）、错误重试（重新生成最后一条）
- [x] 思考过程（reasoning）折叠面板美化：渐变底
- [x] 联网搜索状态与参考来源卡片化
- [x] 错误消息样式：红色弱化 + 重试按钮

### 0.3 UI 待办

- [x] **侧栏行操作区与信息重叠**：hover 快捷按钮（置顶 / 编辑 / 删除）曾盖住
  右侧 token 用量文本——预留位 44pt 小于三按钮实际宽度（约 66pt），且 176pt
  侧栏内标题、时间、消息条数、tokens 挤在同一行。
  - 已实现：① 预留位改为与按钮组实宽一致的常量（`DesignTokens.Sidebar`
    `quickActionsReservedWidth`，约 66pt）；② tokens 用量移到独立子行
    （chart 图标 + 紧凑数值），「日期 · 条数」不再与 tokens 拥挤；
    ③ 侧栏宽度常量移入 DesignTokens 统一入口（176 → 200pt，加宽）。
  - 实测反馈补充：按钮 18pt → 22pt（点击目标更大）；选中行常显快捷按钮
    （无需 hover 即可置顶 / 重命名 / 删除，消除「没有功能 / 有延迟」观感）；
    去掉 hover 淡入动画（即时响应）；hover 状态改为每行自持
    （共享 hoveredSessionID 会被跨行 leave/enter 顺序覆盖，导致按钮闪现消失、
    点击落空）；置顶图标不再用 `pin.slash`（斜线读作禁止），未置顶 `pin` /
    已置顶 `pin.fill`（强调色）；重命名从 `.alert` 弹窗改为行内编辑
    （Enter 确定 / Esc 取消 / ✓✗ 按钮），绕开 NSPanel 上 alert 延迟不出现。
    第三轮：行结构从「ZStack 重叠（整行 Button 叠快捷 Button）」改为
    「行内容与快捷按钮并排 HStack」——macOS 上重叠按钮的点击会被下层按钮
    吃掉（点击 UI 无反应）；快捷按钮样式由 plain 改为 borderless。
  - 护航测试：`SidebarRowLayoutTests`（预留位公式 + hover 正文不越过按钮
    左缘的布局探针 + 真实行挂窗渲染冒烟 + 行内重命名渲染冒烟 +
    快捷操作可见性规则）。

- [x] **空状态 logo 居中**：`emptyState` 保留消息区 ScrollView 的 `else`
  分支，改为「视口高度 minHeight + `alignment: .center`」几何居中，
  窗口高度变化实时重新居中，移除固定 80pt 下移。
  - 实测反馈补充：ScrollView 自身的 `.background(GeometryReader)` 实测回报
    0×0，preference 拿不到尺寸（空状态实际并未居中、短会话顶置 minHeight
    也从未生效）；改为 GeometryReader 包裹 ScrollView 直接取真实消息区尺寸，
    空状态现真正落在消息区垂直中点。
  - **倒排列表必要性已查证，未擅改**：消息区倒置列表（双重旋转）是为绕开
    「LazyVStack 程序化滚动到未物化区域 → 空白」的已知缺陷而保留的取舍；
    空状态不并入倒置容器，仅在 else 分支按视口高度居中，与贴底判断无联动。
  - 护航测试：`EmptyStateCenteringTests`（小 / 大视口下内容中心落在视口中点）
    + `ChatViewRenderTests.testEmptyStateVerticallyCentered`（真实视图像素回归，
    扫描坐标已按位图缩放修正）。

### 0.3 实测反馈修复

- [x] **侧栏快捷按钮点击无响应（已解决）**：根因是 `.buttonStyle(.borderless)`
  在 ScrollView + LazyVStack 中不响应点击（macOS 实测：同一结构下 plain /
  bordered 正常，borderless 无反应；AXPress 同样无效）。修复为改回 `.plain`
  （与行主体按钮一致），保留并排 HStack 结构。
  - 验证：真实应用内注入 AppKit 鼠标事件与 AXPress，快捷按钮 action 均正常
    触发（置顶状态翻转、会话被置顶）；样式对照实验锁定 plain / bordered 可
    点击、borderless 不可点击。测试 190 → 191（AX 暴露回归 + 样式源码守卫）。
  - 教训：2026-07-31 第三轮把 plain 改 borderless 是错误判断——当时 plain
    的失败样本来自 ZStack 重叠阶段，非样式本身问题。

- [x] **置顶状态下快捷操作与选中态失效（已解决）**：真机复测发现置顶后
  「无法取消置顶 / 重命名失效 / 选中态卡在第一个置顶会话、后续置顶会话
  点击无激活态」。根因：嵌套 ForEach（外层分组 + 内层会话）+ LazyVStack
  在会话跨组移动时保留过期行快照（行视图未用新数据重渲染，闭包仍持有
  移动前的 isPinned / 标题），置顶组内的行因此基于过期状态工作。
  - 修复①：侧栏列表拍平为单一 `ForEach(sidebarItems)`（`SidebarItem`
    枚举 = 组头 / 会话行，身份稳定），跨组移动变成同一 ForEach 内的
    identity 移动，SwiftUI 正确更新行内容；
  - 修复②：置顶 / 重命名闭包改为从 `sessionStore` 读当前状态再翻转 /
    取标题，不再依赖闭包捕获的会话快照。
  - 验证：进程内 AX 注入（AXPress / 鼠标事件）驱动真实应用——置顶后行
    立即显示「取消置顶」、点击可取消、置顶中重命名出现输入框、两个置顶
    会话互相切换时选中态只落在一个行上（聊天区标题同步切换）。

- [x] **设置页不再改变窗口尺寸**：设置页曾固定 420pt 宽——内容固有宽度会把
  NSPanel 拽窄（autosave 记住窄尺寸，返回后窗口无法恢复）。改为「撑满窗口 +
  表单限宽 420 居中」；新增 `SettingsWindowSizeTests` 回归（复现：切到设置页
  窗口从 1000 被拽到 420）。

- [x] **自定义窗口大小**：设置页新增「窗口」分区，预设三档——紧凑 70% /
  标准 85% / 铺满 93%（占主屏可见区域比例），UserDefaults 持久化
  （`windowSizePreset`），每次启动按设置生效，不再被 autosave 恢复的旧
  frame 覆盖。
  - 语义已明确：设置档位只在用户显式选择后生效（`SettingsStore`
    `hasChosenWindowSize`）；未设置过的用户保持 autosave 记忆行为；
    设置变更后立即调整当前窗口（`PanelController` 订阅 `$windowSizePreset`），
    无需重启。
  - 实现：`PanelSizing.frame(for:fillRatio:)` 参数化 + `WindowSizePreset`
    领域枚举；护航测试：`PanelSizingTests` 全档位比例 / 居中，
    `SettingsStoreTests` 档位持久化与默认值。

### 输入区 / 侧栏 / 空状态

- [x] 输入框：聚焦高亮描边、发送按钮状态
- [x] 侧栏：按「置顶 / 今天 / 昨天 / 更早」分组；重命名 / 删除已支持
  （右键菜单 + 行内编辑），快捷按钮（置顶 / 重命名 / 删除）与会话图标
  （气泡 / 联网地球）已完成
- [x] 空状态：品牌视觉 + 建议提问 chips（"帮我写周报""解释这段代码"…），点击即发送
- [x] 设置页：卡片化分组（系统 grouped 表单 + 滚动兜底）；API Key 显示/隐藏切换；「测试连接」按钮（调 `/models` 验证 Key）

---

## 三、功能路线图

### Beta 0.2（短期）

- [x] 完成第一节全部 P0 性能优化
- [x] 排版规范落地 + 消息区与输入区美化（0.2.2 完成，见第二节）
- [x] 设置：自定义 System Prompt、temperature 调节
- [x] 会话导入 / 导出（JSON：全量备份 / 恢复 + 单会话导出，导入自动去重 ID）
- [ ] 键盘快捷键：`⌘N` 新建会话、`⌘1~9` 切换、`Esc` 收起面板
- [ ] 全局热键呼出面板（如 `⌥Space`）

### Beta 0.3 / 0.4（中期）

- [x] Markdown 表格与完整 GFM 支持（已集成 MarkdownUI 2.x，解析结果按内容缓存）
- [x] 代码高亮（HighlighterSwift 3.1 + MarkdownUI CodeSyntaxHighlighter，highlight.js 11）
- [x] 自定义模型供应商（OpenAI 兼容 base_url），模型列表可配置
- [x] Token 用量展示与费用估算
- [x] 会话置顶（置顶分组 + hover/右键操作，持久化）；归档 / 标签暂缓
- [x] 自定义窗口大小（见第二节「0.3 UI 待办」）
- [ ] ~~自动标题：模型总结首条消息生成更准确的会话名~~（**已否决**：2026-07
  决定不做，功能鸡肋；保留现有启发式——新建会话以首条消息前 30 字命名）

### 1.0（正式版）

- [ ] 发布渠道：Developer ID 签名 + 公证（notarization），dmg / Sparkle 自动更新
- [ ] App 图标与品牌视觉定稿
- [ ] 无障碍（VoiceOver、动态字体）
- [ ] 多语言（中 / 英）
- [ ] 可选的 iCloud 同步（注意隐私取舍，默认关闭）

---

## 四、工程与流程

- [x] CI：GitHub Actions 跑 `swift test` + release 构建（打 tag 自动传产物）
- [x] 代码规范：接入 `swift-format`（随 Xcode 工具链，零新依赖）+ .editorconfig
- [x] 性能基线：Tests 里新增解析/渲染基准测试（`XCTMeasure`），防止回归
- [x] 崩溃与日志：接入系统日志（os_log），可选 Sentry
- [x] 贡献指南：CONTRIBUTING.md、Issue/PR 模板
- [x] 发布流程文档：docs/RELEASING.md（版本号、changelog、签名公证步骤）
- [x] 架构重构（refactor/architecture，2026-07）：分层拆分（Domain / Services /
  Persistence / Streaming / Views / App）、流式编排抽离 ChatStreamController、
  SessionStoring 协议收窄、AppConfiguration 常量收敛；
  分步计划与验收见 [docs/REFACTORING.md](docs/REFACTORING.md)
- [x] 测试模块化 Phase A（refactor/test-modularization，2026-08）：Tests 目录
  镜像 Sources 分层、大文件按行为面拆分、Support 接口层 + TESTING.md 手册；
  Phase B（多测试 target + TestSupport 模块）与 Phase C（生产代码拆库）的
  规划与触发条件见 [docs/TESTING_ROADMAP.md](docs/TESTING_ROADMAP.md)

---

## 五、长期方向（探索）

- [x] ~~工具调用 / 历史语义搜索~~：已定稿为正式规划，见 [TODO.md](TODO.md)
- [ ] 语音输入（macOS 听写 / Whisper API）
- [ ] 多标签页 / 分屏对比回复
- [ ] 本地隐私模式：会话加密存储

---
