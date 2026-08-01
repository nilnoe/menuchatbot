# 版本更迭

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格记录各版本变化。

## [0.3.3] - 2026-08-01

### 变更（Tier 4 方向修订 + T1 read_file + T4-4 落地）

- **Tier 4 方向修订**：T2 Python 沙箱（seatbelt 弱隔离）降级为暂缓——
  收益 / 可控性不成比例，无 Agent 需求则无刚需（ADR-0006 修订 + TODO
  Tier 4 + ACCEPTANCE §7 同步）；Tier 4 收窄为 T1 read_file + 工具审计。
- **T1 read_file（结构化只读中间层）**：模型不接触 shell，经 MCP 风格
  JSON 参数调用 `read_file`（相对授权根目录的路径 + 起止行号）；执行器
  做 PathScope 包含校验（拒绝 `../` 与 symlink 逃逸）、扩展名白名单、
  1MB 大小上限 / 200 行单次上限 / 单行 4000 字符截断 / 输出总量上限，
  越权与非法范围返回明确错误；工具注册、设置开关、审计挂点复用现有基建。
- **T4-4 工具执行记录**：tool 消息升级为自包含完整记录——状态（成功 /
  失败）、工具名、耗时、参数（截断 200 字符）、结果 / 错误，写入会话
  历史并随 tool 消息回传 API；新增失败路径测试覆盖。
- **后续计划登记**：P1.5 检索注入审计、「两级阅读」衔接（Source 卡片 →
  read_file 精读）、工具结果 token 记账、BM25 检索替换（见 TODO）。

## [0.3.2] - 2026-08-01

### 功能（Tier 3：资料库 RAG）

- **library_index（T3-1）**：Rust 侧 `RustCore/src/library.rs`——根目录
  扫描（规范化 + symlink 包含检查，拒绝逃逸；跳过隐藏 / 二进制 / 超大 /
  白名单外 / 依赖目录）、分块（默认 600 token、重叠 120，CJK 1 字符 ≈ 1
  token，超大段自动切片）、增量（path + mtime + contentHash 全同才跳过，
  改 / 删 / 增文件重扫一致）、扩展名白名单（默认 24 种文本扩展名可配置）。
- **embedding（T3-1 mock 先行）**：`RustCore/src/engine.rs`——
  `Embedder` trait（candle 本地模型 / 远程 OpenAI 兼容预留）+ 确定性
  mock 实现（词元 + 字符 bigram 哈希向量，L2 归一化，余弦检索）；
  T3-1a recall@5 ≥ 0.8 fixture 校准通过。
- **索引落盘与版本化（T3-2c）**：`dc_index_open(path)` 支持落盘目录，
  `save` / `load` 版本化 JSON（临时文件 + rename 原子替换），旧版本文件
  忽略重建；索引可整体删除重建（派生数据原则）；`dc_index_cancel` 改为
  操作级取消标志（只影响长任务，不再闩锁禁用搜索 / 写入），取消后部分
  进度已落盘可续跑。
- **新 ABI**：`dc_index_index_corpus`（扫描 → 分块 → mock embedding →
  增量更新 → 报告 JSON）；`dc_index_status` 扩展 `files` / `indexed_at`；
  INDEX_VERSION 1 → 2；rustcore.h / stub / ABI 校验同步。
- **Swift 桥接**：`RustIndexService` 支持索引目录与
  `indexCorpus` / `librarySnapshot` / `cancelIndexing`；新增
  `LibraryIndexing` 协议 + `RustLibraryIndexer`（每库一句柄，
  `<indexRoot>/<corpusID>/`）+ `MockLibraryIndexer`（测试 / 降级）；
  `SearchScope.library(corpusID)` 按库隔离（namespace = `library/<id>`）；
  `SearchHit` 携带来源路径。
- **检索注入（T3-3）**：`LibraryRetrievalInjector`——发送前对最后一条
  用户消息检索启用资料库，各库 top-k → 按文件去重 → token 预算裁剪
  （默认 6k，4~8k 可配，低于阈值不注入）→ system 前缀注入上下文；
  命中文件复用现有 `Source` 模型展示参考来源（标题 = 文件名，url = 路径），
  ChatStreamController 首轮前接线，空结果不注入。
- **命名资料库 UI（T3-5）**：设置页「本地资料库」——名称 / 路径 / 启用
  开关 / 删除（走模型清理索引）、单库重新索引按钮、索引状态（文件数 /
  分块数 / 最近索引时间 / 错误）、全局进度与取消；`LibraryIndexModel`
  （MainActor）驱动后台任务，TCC security-scoped bookmark 恢复后索引，
  启动时对启用库做增量索引。
- **测试与门禁**：新增 16 个 Swift 测试（协议 2 / FFI 语料 3 / 注入 5 /
  流式注入 2 / 模型 4，共 334 全绿）+ Rust 新增 27 个测试（共 54 + 集成 1
  全绿，clippy / fmt 零违规）；`check-scale.sh` 阈值第三次校准
  （Sources 8000 → 9000、Tests 7500 → 8500、单测试文件 600 → 700，
  原因登记于脚本头）。

### 修复

- **检索性能**：`dc_index_search` 的查询向量（embedding）与查询词元
  由 per-doc 闭包内重复计算改为循环外只算一次；history 分支文档小写
  每文档只做一次（原来每 token 重复 lowercase 全文）。新增计数 Embedder
  防回归测试断言「一次搜索恰好 embed 一次」。
- **编译警告**：`RustIndexService.indexCorpus` 的 `Task.detached` 捕获
  非 Sendable 的 `OpaquePointer`（Swift 6 严格并发下将报错）→ 增加
  `@unchecked Sendable` FFI 句柄包装；移除多余的 `try`。`make-app.sh`
  全流程零警告。

## [0.3.1] - 2026-08-01

### 功能（Tier 2：Rust 骨架与工具链）

- **Rust 核心静态库落地（T2-1）**：新增 `RustCore` crate（staticlib + 最小
  C ABI，11 个导出符号，JSON 出入，`panic=abort`，零第三方依赖可离线构建）；
  手写头文件 `Sources/CRustCore/include/rustcore.h`；SwiftPM 新增
  `CRustCore` C target 与 `DeepSeekChatIndexing` 库（`IndexService` 协议 +
  `RustIndexService` + `MockIndexService`，Streaming / Views 只依赖协议，
  不接触 C 类型）。`scripts/build-rust-core.sh` 统一产出
  `RustCore/dist/librustcore.a`：release 双架构 lipo + strip + ABI 符号
  校验；无 cargo 环境自动降级为同 ABI stub 库（`swift test` 全绿、FFI 集成
  测试 XCTSkip，T2-1d）；`make-app.sh` 开头接入；CI 新增 rust
  fmt / clippy / test job 与无 Rust 工具链的 test-degraded job。
- **T0 计算器（T2-2）**：Rust 表达式求值器 `dc_eval_expr`（四则 / 优先级 /
  括号 / 幂 / 取模 / 一元符号 / 小数与科学计数法），非法表达式返回错误码
  不 panic、不跨 FFI unwind；Swift 侧 `RustCalculatorService` + 设置页
  「计算器」开关接入工具注册表。
- **工具调用循环（T2-3）**：Chat Completions function calling 全链路——
  流式 `tool_calls` 分片解析拼装（ToolCallAccumulator）→ 本地执行 →
  结果回填 → 继续生成；轮次上限（默认 3，超过后强制收敛）；每次调用以
  tool 消息写入会话历史（工具名 / 参数 / 结果摘要，UI 透明展示）；取消后
  不再执行后续工具；message 表 v5 迁移补工具列（旧库升级保留数据）。
  Responses 的 function 工具随 v4-pro 开放跟进。
- **深度思考 v1（T2-4）**：`reasoning_effort=max` 档位（UI 已有 Max，
  补充 Chat Completions / Responses 请求构造测试）。

### 功能（Tier A：审计模块 P1）

- **审计地基**：新增 `Sources/DeepSeekChat/Audit/`（ADR-0009）——
  `AuditEvent` / `AuditDomain` / 事件目录 70 种（`AuditCategory`）、字段级
  脱敏（`AuditRedactor`，密钥 / 全文 / 长路径截断 + SHA-256）、追加式
  `AuditStore`（独立 `audit.sqlite`，自有迁移链，无 update / delete API，
  90 天 / 50MB 保留策略）、`AuditLogger`（批量异步落 sink，故障不阻塞业务）、
  `AuditCenter` 组合根（审计库损坏自动降级内存库）。设置页新增「安全审计」
  查看器（级别 / 域过滤 + 导出，导出不含密钥与全文）。
- **四域接入**：A 配置（SettingsStore：模型 / 工具开关 / 供应商 / 资料库
  增删 / 推演时长 / API Key 生命周期，密钥只记事件不记值）；B 权限
  （PathScope 通过 / 拒绝事件、bookmark 授权与 stale、注册表白名单自检、
  轮次上限强制收敛）；C 工具（executeTool 每次调用 start / end 成对 +
  requestID 贯穿 + 耗时 / 结果摘要）；D 存储（SessionStore：迁移 / DB 降级
  / 导出导入 / 会话删除，审计记录独立保留）。
- **测试与门禁**：新增 43 个审计测试（共 315 全绿，覆盖 AU-1~AU-21 中
  P1 可验条目）；`check-scale.sh` 阈值按 ADR-0009 D8 校准（6000 → 7500，
  原因记录于脚本头）；SessionStore 拆出 `SessionStore+Audit` /
  `SessionStore+Migrations` 满足单文件 ≤ 800 行。

### 功能（Tier A：审计模块 P2 —— FFI 审计与 CI 加固）

- **Rust 审计模块**：`RustCore/src/audit.rs`——错误码计数器、调用计数、
  分配 / 释放配对计数、panic 环形缓冲与崩溃日志；`std::panic::set_hook`
  把 panic 现场（消息 + 位置）先写入审计再走默认 hook（`panic=abort`
  语义不变）。
- **新 ABI**：`dc_audit_init`（幂等安装 panic hook + 崩溃日志路径）与
  `dc_audit_snapshot`（计数器 + 环形缓冲 JSON，`dc_free` 释放）；头文件、
  stub 降级库、`build-rust-core.sh` ABI 校验数组同步（13 个导出符号）。
- **Swift 桥接**：`DeepSeekChatIndexing/RustAudit.swift`（install +
  snapshot 解析，stub 降级为 no-op）；`AuditCenter` 启动安装 + 每 60s
  增量采集，把错误码增量 / panic / 泄漏落为 `ffi.*` 事件。
- **CI 加固**：rust job 加 `cargo audit`（供应链漏洞扫描，AU-17）且
  `cargo test` 单线程执行（全局计数器确定性，AU-13/14）；新增 cron
  `fuzz` job（cargo-fuzz 打 `dc_eval_expr` / `dc_index_upsert` 输入边界，
  ≥ 10 万迭代，AU-16）；新增 `asan` job（FFI 测试在 Address Sanitizer 下
  运行，AU-14）；`RustCore/tests/fuzz_smoke.rs` 提供常驻 10 万次确定性
  冒烟。
- **测试**：Rust 35 全绿（新增 AU-13/14/15 + fuzz 冒烟）、Swift 318 全绿
  （新增 FFI 快照 / 采集事件测试）。

### 重构

- **测试代码模块化**：`Tests/` 目录镜像 `Sources` 分层（App / Domain /
  Services / Persistence / Streaming / Views / Performance / Support）；
  大测试文件按行为面拆分（`SessionStoreTests` 739 行 → 5 个、
  `DeepSeekClientTests` → 3 个、`SSEParserTests` → 4 个、
  `SettingsStoreTests` → 2 个）；共享测试支持收敛为 `Support/` 接口层
  （Harness + Mock + 工厂），新增 [docs/TESTING.md](docs/TESTING.md)
  测试策略与支持 API 手册。191 个测试全部通过，行为不变。

### 工程

- **规模检查**：新增 `scripts/check-scale.sh`，限制源码 / 测试总行数与单文件
  大小上限（防"上帝文件"回归），本地与 CI（scale job）共用；超限即构建失败，
  阈值可用环境变量覆盖。

### 文档与规划

- **审计模块方案定稿（纯文档，未实现）**：新增
  [ADR-0009](docs/decisions/0009-audit-module.md)（威胁模型、7 审计域、
  事件目录 70 种、独立 `audit.sqlite` 追加式存储、字段级脱敏、90 天 /
  50MB 保留策略、FFI 计数器 + panic hook + `dc_audit_snapshot`、
  cargo audit / fuzz / ASan CI 门禁）与
  [ACCEPTANCE §11](docs/ACCEPTANCE.md) 量化验收（AU-1~AU-21，每条
  先红后绿）；TODO 新增「Tier A｜审计模块」登记 P1~P4 实施步骤。
  代码实现待方案验收通过后启动。
- **Rust 核心与 AI 能力规划定稿（纯文档，无代码改动）**：确定 Rust 核心
  集成方案 A（静态库 + C ABI + Swift 协议隔离）、本地资料库 RAG（命名
  资料库 + 授权 + 引用复用）、MCP 兼容本地工具宿主（分级工具 + 只读 +
  非 Agent 约束）、长时推演模式（时间预算驱动的多阶段思考，区别于官方
  `reasoning_effort`）。新增 ADR-0004~0007 与
  [docs/DESIGN_RUST_CORE.md](docs/DESIGN_RUST_CORE.md)，TODO 新增
  「Rust 核心与 AI 能力规划」并按实现难度分层（先易后难）。
- **重构评估定稿（纯文档）**：新增 [ADR-0008](docs/decisions/0008-refactor-assessment.md)
  明确「结构不重构、数据与接口地基先行、target 拆分后置」；TODO Tier 1
  调整为「第一批数据地基 → 第二批接口地基」并补齐验收标准。
- **TODO 拆分（纯文档）**：历史内容（性能记录 / UI 改进 / Beta 0.2~1.0
  路线 / 工程记录 / 长期探索）移入 [TODO_HISTORY.md](TODO_HISTORY.md) 并
  **降级为低优先级归档**；[TODO.md](TODO.md) 保留现行规划（优先级备忘 +
  Rust 核心与 AI 能力路线 + 历史 backlog 索引），README / 文档地图 /
  ADR-0002 引用同步更新。
- **非 UI 验收标准（纯文档）**：新增 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)
  定义可测量 / 可复现 / 可自动执行的验收框架（行为等价、性能阈值、数据
  完整性、安全边界、评审清单）；TODO 各 Tier 挂接对应验收章节，CONTRIBUTING
  增加非 UI 改动检查项。

### 数据层（Tier 1 第一批，进行中）

- **消息表派生列（v4 迁移）**：message 表新增 `tokenTotal` / `contentHash` /
  `indexVersion`；旧库升级按 usageJSON 回填 tokenTotal；新增稳定内容指纹
  `ContentHash`（FNV-1a 64，跨启动稳定，替代随机播种的 `Hasher`）；
  新增 hash 确定性 / 派生列持久化 / 旧库升级迁移测试。测试 191 → 198。
- **SessionSummary 拆分（惰性加载）**：`SessionStore.sessions` 改为仅元数据
  的 `[SessionSummary]`（条数 / token 合计 / 最后来源由 SQL 聚合）；
  消息正文按需 `messages(for:)` 惰性加载 + 3 会话 LRU 缓存，启动不再
  全量物化；侧栏行改用 summary（消除每行 reduce）；导入导出直读数据库；
  `SessionStoring` 协议新增 summaries 契约。新增 summary 行为测试 7 个。
- **消息分页（Tier 1-1e）**：新增 `messagesTail(for:limit:)` /
  `messagesBefore(_:sessionID:limit:)` 分页 API；ChatView 首次只渲染尾部
  200 条，上翻到分页边界自动加载更旧一页（倒置列表 oldest 物化触发）。
  新增分页测试 5 个（测试 203 → 208）。
- **数据地基性能基线**：新增 `DataFoundationBaselineTests`——启动加载
  1 万消息、侧栏派生计算（200 会话）、流式存储吞吐（XCTMeasure），
  阈值按 ACCEPTANCE §9 先测后校。
- **流式写放大修复（Tier 1-3）+ messageStates LRU（Tier 1-4）**：UI 保持
  40ms 聚合，落库降频至每 6 次（~240ms），中间 `syncMessage` 只写消息行、
  不再 touch 会话时间戳（写放大约 -12x），`commitMessage` 统一落库时间戳
  保证崩溃恢复语义；消息状态上限 200 条 LRU 逐出（当前会话/流式消息因
  渲染频繁而保持新鲜）。新增落库时序与 LRU 测试 3 个（测试 211 → 214）。
- **接口地基（Tier 1 第二批，第一批）**：新增 `ContextBuilder` 统一上下文
  预算（字符启发式 token 估算 + 尾部截断 + 最后一条消息保底），
  `ChatStreamController` 历史改经 ContextBuilder 构建；新增
  `IndexEventPublishing` / `IndexEvent` 契约，SessionStore 在
  append / update / commit / delete / 导入时发布索引事件（流式中间写回
  不发布，避免洪泛）。新增测试 8 个（测试 214 → 222）。
- **工具契约（Tier 1 第二批，第二批）**：新增 `ToolTier`（T0~T2，无 T3
  shell）、`ToolDefinition`（MCP 风格 JSON Schema）、`ToolExecuting` /
  `ToolRegistry` 协议与进程内注册表（名称唯一、分级、查询）；执行器
  实现随 Tier 2。新增注册表测试 6 个（测试 222 → 228）。
- **设置模型与路径授权（Tier 1 第二批，第三批）**：新增 `LibraryCorpus`
  （命名资料库 + bookmark）与 `DeliberationDuration`（5/10/20/30 分钟）
  领域模型；SettingsStore 增加 corpora / 推演时长 / 工具开关（计算器默认
  开，只读文件与 Python 沙箱默认关）并持久化；新增 `PathScope` 路径包含
  检查（`..` 与 symlink 逃逸拒绝、根目录拒绝、最长存在祖先解析）与
  `SecurityScopedBookmark`；设置页新增「本地资料库 / AI 能力」分区
  （目录选择经 NSOpenPanel + bookmark）。新增测试 11 个（测试 228 → 239）。

## [0.3.0] - 2026-08-01

### 新增

- **0.3 UI 收尾（含实测反馈修复）**
  - **侧栏行信息重叠修复**：会话行 hover 快捷按钮（置顶 / 重命名 / 删除）的
    正文预留位从估算的 44pt 改为与按钮组实宽一致的常量
    （`DesignTokens.Sidebar`，约 66pt），文字不再被按钮覆盖；token 用量从
    「日期 · 条数」同行挤出改为独立子行（chart 图标 + 紧凑数值），侧栏信息
    不再拥挤，长标题 hover 时也能完整展示。
    - 实测反馈补充：快捷按钮由 18pt 加大到 22pt（点击目标更大）；选中行
      常显快捷按钮（无需 hover 即可置顶 / 重命名 / 删除，规则可单测）；
      去掉 hover 淡入动画，按钮即时出现，消除「点了没反应 / 有延迟」的观感。
  - **空状态垂直居中**：空状态改为按消息区视口高度居中（视口高度做 minHeight
    + `alignment: .center`），窗口高度变化时实时重新居中，替换 0.2.2 的固定
    `padding(.top, 80)` 粗略下移。
    - 实测反馈补充：修复视口尺寸测量——ScrollView 自身的
      `.background(GeometryReader)` 实测回报 0×0，空状态实际并未居中；
      改为用 GeometryReader 包裹 ScrollView 取真实消息区尺寸（踩坑细节见
      [docs/PITFALLS.md](docs/PITFALLS.md) §2.2）。
  - **对话列与主区等比缩放**：消息列由固定 780pt 上限改为占主区宽度 86%
    （两侧各留 7% 空隙），用户 / assistant 气泡按列宽 66% / 92% 等比缩放，
    调整窗口时「对话与主区」比例保持不变、两侧空隙等比变化
    （替换 0.2.x 固定 780 / 520 / 720 设计）。
  - **自定义窗口大小**：设置页新增「窗口」分区，可选 紧凑 70% / 标准 85% /
    铺满 93% 三档（占主屏可见区域比例，默认 93% 与 0.2.x 一致）。用户选择
    后每次启动按档位居中生效，覆盖 autosave 恢复的旧窗口大小，设置变更立即
    作用于当前窗口；从未设置过的用户保持原有窗口记忆行为。窗口计算收敛到
    `PanelSizing.frame(for:fillRatio:)`，侧栏宽度常量移入 DesignTokens。
  - 测试从 175 增至 189：侧栏行布局回归（预留位公式 + hover 不重叠探针 +
    真实行渲染冒烟 + 快捷操作可见性规则）、空状态居中（小 / 大视口 +
    真实 ChatView 像素回归）、气泡宽度随窗口等比缩放、窗口档位计算与持久化。
    其中 ChatView 像素测试的扫描坐标按位图缩放修正（`colorAt` 为像素坐标）。
  - 版本号升至 0.3.0（`scripts/make-app.sh` Info.plist 同步）。
- **实测反馈修复（第二轮）**
  - **侧栏快捷操作偶发失效**：共享 `hoveredSessionID` 被跨行 leave/enter
    顺序覆盖导致按钮闪现消失（踩坑细节见 [docs/PITFALLS.md](docs/PITFALLS.md)
    §1.4）。改为每行自持 hover 状态。
  - **侧栏按钮点击没反应（第三轮）**：整行 Button 与快捷 Button 在 ZStack
    重叠，点击被下层行 Button 吃掉；改为并排 HStack（踩坑细节见
    [docs/PITFALLS.md](docs/PITFALLS.md) §1.1）。
    - 更正（2026-08-01）：当时一并把快捷按钮由 plain 改为 borderless，经
      实测是错误判断——borderless 在滚动列表点击无响应（见
      [docs/PITFALLS.md](docs/PITFALLS.md) §1.2），已改回 plain。
  - **重命名改为行内编辑**：`.alert` 在 NSPanel 上延迟 / 不出现（踩坑细节见
    [docs/PITFALLS.md](docs/PITFALLS.md) §1.5），改为行内输入框
    （Enter 确定、Esc 取消、右侧 ✓/✗ 按钮）。
  - **置顶图标**：不再用 `pin.slash`（斜线读作「禁止」），未置顶 `pin`、
    已置顶 `pin.fill`（强调色）；点击取消置顶后会话回归初始分组位置。
  - **侧栏加宽**：176 → 200pt（`DesignTokens.Sidebar.width`）。
  - **设置页不再改变窗口尺寸**：固定 420pt 宽曾被 autosave 记住、返回后窗口
    无法恢复（踩坑细节见 [docs/PITFALLS.md](docs/PITFALLS.md) §5.1）；
    改为「撑满窗口 + 表单限宽 420 居中」。新增 `SettingsWindowSizeTests` 回归。
  - 测试从 189 增至 190。

### 修复

- **侧栏会话行快捷按钮点击无响应（已解决，2026-08-01）**：`.borderless`
  按钮在 ScrollView + LazyVStack 中 action 不触发（根因与验证方法见
  [docs/PITFALLS.md](docs/PITFALLS.md) §1.2 / §6.1）——2026-07-31 第三轮
  误将 plain 改为 borderless 反而引入该问题。修复：改回 `.plain`（并排
  HStack 结构保留）。验证：进程内 AXPress + AppKit 事件注入 + 样式对照
  实验；测试从 190 增至 191（plain 样式源码守卫）。

- **置顶状态下快捷操作与选中态失效（已解决，2026-08-01）**：嵌套
  ForEach + LazyVStack 跨组移动保留过期行快照（根因详见
  [docs/PITFALLS.md](docs/PITFALLS.md) §1.3）。修复：① 列表拍平为单一
  `ForEach(sidebarItems)`（组头 / 会话行身份稳定）；② 置顶 / 重命名闭包
  从 `sessionStore` 读当前状态。验证：进程内 AX 注入驱动真实应用，
  取消置顶 / 置顶中重命名 / 多置顶会话切换均正常。

- **会话置顶（Beta 0.3）**
  - 侧栏新增「置顶」分组（排在时间分组之前）；hover 快捷按钮与右键菜单
    均可置顶 / 取消置顶，状态持久化（GRDB `session.isPinned` 列，v3 迁移
    自动升级旧库；置顶不改变 updatedAt，不影响时间分组）。
  - 旧备份 JSON 缺少 isPinned 字段时解码回退未置顶，导入兼容。
  - 测试从 171 增至 175（置顶持久化、不动 updatedAt、旧库迁移、旧备份解码、
    侧栏渲染冒烟覆盖置顶行）。
  - **否决记录**：自动标题（模型总结首条消息）确认不做，功能鸡肋。

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

> 踩坑与开发经验自 2026-08 起统一收录于 [docs/PITFALLS.md](docs/PITFALLS.md)
> （本文档只记录版本变更，不再承载知识库）。
