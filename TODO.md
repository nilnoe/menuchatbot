# MenuChatBot 开发路线图（TODO）

> 版本状态：Beta 0.3（2026-07-31）
> 本文档记录性能问题、UI 改进与发展规划。条目以 checkbox 标记进度。

> **当前进展（0.2.1）**：Beta 0.2 收尾（System Prompt / temperature、会话导入导出、代码高亮）与工程加固（CI、swift-format、性能基线、os_log、贡献/发布文档）完成；
> 0.2.0 的性能里程碑见 [CHANGELOG.md](CHANGELOG.md)。
>
> **当前进展（0.2.2）**：排版规范落地（设计 token）+ 消息区/输入区美化、代码块卡片、侧栏日期分组、空状态建议 chips、
> 统一系统表面风格、短会话顶置、默认窗口 93% 铺满、设置页收尾（卡片化分组 + API Key 显示/隐藏 + 测试连接）。
>
> **当前进展（重构后）**：分层架构重构完成并合并至 main（见 [docs/REFACTORING.md](docs/REFACTORING.md)），
> 测试 146 全绿；重构只动结构不动行为，功能路线图不受影响。
>
> **当前进展（0.3 起点）**：自定义模型供应商（OpenAI 兼容 base_url）落地——设置页可启用
> 自定义供应商、配置 API 地址与模型列表；请求自动切换到自定义地址，DeepSeek 专属参数
> （thinking / reasoning_effort / 联网搜索）对自定义模型省略；
> 侧栏 hover 快捷操作与会话图标收尾 Beta 0.2；Token 用量展示与费用估算落地
> （流式 include_usage 解析、按消息持久化、消息行/侧栏展示、官方单价估算）；
> 会话置顶落地（置顶分组 + hover/右键置顶操作，GRDB v3 迁移）；
> 自动标题已否决（见下）；测试 175 全绿。
>
> **当前进展（0.3 UI 收尾）**：侧栏行信息重叠、空状态 logo 不居中、自定义
> 窗口大小三项全部完成（2026-07-31，见第二节「0.3 UI 待办」勾选）；
> 测试从 175 增至 185。
>
> **下一步方向**：① 键盘快捷键（⌘N / ⌘1~9 / Esc 收面板）与全局热键
> （如 ⌥Space）按需求暂不做；② Beta 0.4 候选：归档 / 标签、多语言、
> 无障碍（见下）；③ 1.0 路径：Developer ID 签名公证 + dmg + Sparkle 更新。

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
- [x] 消息列居中：消息区限制最大宽度 780pt 居中，避免满屏拉长

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
    ③ 侧栏宽度 176pt 常量移入 DesignTokens 统一入口。
  - 护航测试：`SidebarRowLayoutTests`（预留位公式 + hover 正文不越过按钮
    左缘的布局探针 + 真实行挂窗渲染冒烟）。

- [x] **空状态 logo 居中**：`emptyState` 保留消息区 ScrollView 的 `else`
  分支，改为「视口高度 minHeight + `alignment: .center`」几何居中，
  窗口高度变化实时重新居中，移除固定 80pt 下移。
  - **倒排列表必要性已查证，未擅改**：消息区倒置列表（双重旋转）是为绕开
    「LazyVStack 程序化滚动到未物化区域 → 空白」的已知缺陷而保留的取舍；
    空状态不并入倒置容器，仅在 else 分支按视口高度居中，与贴底判断无联动。
  - 护航测试：`EmptyStateCenteringTests`（小 / 大视口下内容中心落在视口中点）。

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
- [x] 侧栏：按"今天 / 昨天 / 更早"分组；重命名 / 删除已支持（右键菜单 + 弹窗），
  快捷 hover 按钮（重命名 / 删除）与会话图标（气泡 / 联网地球）已完成
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

---

## 五、长期方向（探索）

- [ ] 工具调用（Tool Calls）：让模型调用计算器、日历等本地工具
- [ ] 历史语义搜索（本地 embedding + 向量检索）
- [ ] 语音输入（macOS 听写 / Whisper API）
- [ ] 多标签页 / 分屏对比回复
- [ ] 本地隐私模式：会话加密存储

---

## 六、优先级与决策备忘

- 性能 > 功能：Beta 0.2 先做"长会话不卡"，再做新功能
- 原生质感 > 花哨动效：毛玻璃与排版优先于自定义动画
- 发布路径：先 GitHub Release 免费分发，正式版再考虑 App Store
- 隐私底线：API Key 只在钥匙串；会话数据默认不离开本机
