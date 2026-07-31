# MenuChatBot 开发路线图（TODO）

> 版本状态：Beta 0.2（已发布，2026-07-31）
> 本文档记录性能问题、UI 改进与发展规划。条目以 checkbox 标记进度。

> **当前进展（0.2.0）**：长会话/长输出性能问题全部解决（P0×3、P1×2、存储演进 SQLite、MarkdownUI 实时渲染、倒置列表），
> 详见 [CHANGELOG.md](CHANGELOG.md)。
>
> **下一步方向**：① Beta 0.2 收尾：排版规范 + 消息区/输入区美化、设置（System Prompt / temperature）、会话导入导出、快捷键；
> ② 工程加固：CI（GitHub Actions）+ 性能基线（XCTMeasure，防回归）+ os_log；
> ③ Beta 0.3：会话内全文搜索（SQLite FTS5 已就绪）、代码高亮、自定义模型供应商。

---

## 一、已知问题：长会话卡顿（性能）

### 根因分析

当前流式回复时，每次收到一个 token 分片都会触发整棵视图树重算，工作量随会话长度**平方级**增长：

1. **全量重渲染**
   `SessionStore.updateMessage()` 每次分片都调用 `objectWillChange.send()`，而 ChatView / SidebarView 都观察整个 `sessions` 数组 → 每次 delta 全会话重算。会话越长越卡。
   - 涉及：`Stores.swift`（SessionStore）、`Views/ChatView.swift`

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

- [ ] 面板毛玻璃：窗口透明 + `NSVisualEffectView`（.hudWindow / .sidebar material），圆角 14~16 + 阴影，贴近系统菜单栏工具质感
- [ ] 明暗模式与系统强调色适配；品牌色（如 DeepSeek 蓝紫渐变）只用于点缀
- [ ] 消息列居中：大窗口下消息区限制最大宽度（约 780pt）居中，避免满屏拉长

### 排版规范

- [ ] 建立设计 token：字号梯度（caption/callout/body）、行高（1.5~1.65）、统一间距（4/8/12/16）、圆角（6/10/14）
- [ ] 代码统一使用 SF Mono，行内代码与代码块样式（语言标签 + 复制按钮）
- [ ] 中文排版优化：标题与正文层级、列表/表格间距、引用块样式

### 消息区

- [ ] 消息时间戳（悬浮显示或轻量显示）
- [ ] 用户消息带头像；assistant 消息带模型标签（V4 Flash / V4 Pro）
- [ ] 气泡出现动画（淡入 + 轻微上移），分组连续消息
- [ ] 消息操作：复制按钮（纯文本 / Markdown 源码）、重试（重新生成最后一条）
- [ ] 思考过程（reasoning）折叠面板美化：渐变底、展开动画
- [ ] 联网搜索状态与参考来源卡片化
- [ ] 错误消息样式：红色弱化 + 重试按钮

### 输入区 / 侧栏 / 空状态

- [ ] 输入框：聚焦高亮描边、发送按钮状态、流式时的停止按钮动效
- [ ] 侧栏：按"今天 / 昨天 / 更早"分组；hover 显示重命名/删除；会话图标
- [ ] 空状态：品牌视觉 + 建议提问 chips（"帮我写周报""解释这段代码"…），点击即发送
- [ ] 设置页：卡片化分组；API Key 显示/隐藏切换；「测试连接」按钮（调 `/models` 或最小请求验证 Key）

---

## 三、功能路线图

### Beta 0.2（短期）

- [x] 完成第一节全部 P0 性能优化
- [ ] 排版规范落地 + 消息区与输入区美化（第二节核心项）
- [ ] 设置：自定义 System Prompt、temperature 调节
- [ ] 会话导入 / 导出（JSON）
- [ ] 键盘快捷键：`⌘N` 新建会话、`⌘1~9` 切换、`Esc` 收起面板
- [ ] 全局热键呼出面板（如 `⌥Space`）

### Beta 0.3 / 0.4（中期）

- [x] Markdown 表格与完整 GFM 支持（已集成 MarkdownUI 2.x，解析结果按内容缓存）
- [ ] 代码高亮（Highlightr 或 swift-highlight）
- [ ] 会话内全文搜索
- [ ] 自定义模型供应商（OpenAI 兼容 base_url），模型列表可配置
- [ ] Token 用量展示与费用估算
- [ ] 会话置顶 / 归档 / 标签
- [ ] 自动标题：模型总结首条消息生成更准确的会话名

### 1.0（正式版）

- [ ] 发布渠道：Developer ID 签名 + 公证（notarization），dmg / Sparkle 自动更新
- [ ] App 图标与品牌视觉定稿
- [ ] 无障碍（VoiceOver、动态字体）
- [ ] 多语言（中 / 英）
- [ ] 可选的 iCloud 同步（注意隐私取舍，默认关闭）

---

## 四、工程与流程

- [ ] CI：GitHub Actions 跑 `swift test` + release 构建（自动打 tag 传产物）
- [ ] 代码规范：接入 `swift-format` 或 SwiftLint，.editorconfig
- [ ] 性能基线：在 Tests 里加解析/渲染基准测试（`XCTMeasure`），防止回归
- [ ] 崩溃与日志：接入系统日志（os_log），可选 Sentry
- [ ] 贡献指南：CONTRIBUTING.md、Issue/PR 模板
- [ ] 发布流程文档：版本号、changelog、签名公证步骤

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
