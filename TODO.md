# DeepSeek Chat 开发路线图（TODO）

> 版本状态：Beta 0.3.2（2026-08-01）
> 本文档是**现行规划**：工程原则 + Rust 核心与 AI 能力路线。
> 历史 TODO（性能记录 / UI 改进 / Beta 0.2~1.0 路线 / 工程记录 / 长期探索）
> 已拆分至 [TODO_HISTORY.md](TODO_HISTORY.md)，**降级为低优先级归档**，
> 以本文档为准。全部文档索引见 [docs/README.md](docs/README.md)。

> **当前状态（2026-08-01）**：测试 334 全绿（cargo test 54 + 集成 1）；
> 分层架构重构与测试模块化
> Phase A 已完成（细节见 TODO_HISTORY.md / CHANGELOG.md）；Tier 2
> 「Rust 骨架与工具链」全部落地（RustCore staticlib + C ABI、构建链与
> 无 cargo 降级、IndexService 协议 + Rust/Mock 实现、T0 计算器、
> 工具调用循环、effort=max），细节见 CHANGELOG.md；审计模块方案已定稿
> （ADR-0009 + ACCEPTANCE §11）；Tier A P1（审计地基 + 四域接入 +
> 设置页查看器）已实现，P2~P4 待做（见 Tier A）；Tier 3 资料库 RAG
> 主体已落地（见下）。
>
> **历史进展存档**：0.2.x 性能里程碑、0.3 功能与 UI 收尾等逐项细节见
> [CHANGELOG.md](CHANGELOG.md) 与 [TODO_HISTORY.md](TODO_HISTORY.md)。
>
> **下一步方向**：Tier 3 剩余项（candle 本地 embedding 接入、FSEvents
> 增量监听、重建分片进度回调）与 Tier 4（只读文件 / 脚本沙箱）；键盘
> 快捷键 / 全局热键 / 1.0 发布项等原
> backlog 已降级至 TODO_HISTORY.md，按需再捞起。

---

## 一、优先级与决策备忘

- 性能 > 功能：先做「长会话不卡」，再做新功能
- 原生质感 > 花哨动效：毛玻璃与排版优先于自定义动画
- 发布路径：先 GitHub Release 免费分发，正式版再考虑 App Store
- 隐私底线：API Key 只在钥匙串；会话数据默认不离开本机
- 安全 > 功能：资料库授权与工具沙箱先于检索体验；「不做 Agent」是硬约束

---

## 二、Rust 核心与 AI 能力规划（2026-08-01 定稿）

> 方向已定稿：ADR-0004（Rust 集成方案 A）、ADR-0005（资料库 RAG）、
> ADR-0006（MCP 工具宿主）、ADR-0007（长时推演）、ADR-0008（重构评估与
> 执行顺序）；详细设计见 [docs/DESIGN_RUST_CORE.md](docs/DESIGN_RUST_CORE.md)。
> 按实现难度分层、**先易后难**；每层独立可合并、可回滚，落地时小步 +
> 测试护航（沿用 refactor/architecture 的验收纪律）。

### Tier 1｜地基（纯 Swift，低难度，可先行）

**第一批｜数据地基**（ADR-0008 D2）

- [x] SessionStore 拆分 SessionSummary（侧栏不再持有消息正文；token 合计
  来自派生列 SQL 聚合，消除每行 reduce；启动不再全量物化消息，改为惰性
  加载 + LRU 缓存）
- [x] 消息分页：ChatView 尾部 200 条 + 上翻增量加载（Tier 1-1e，
  store 层分页 API + 渲染接线）
- [x] 消息表派生列：tokenTotal / contentHash / indexVersion（GRDB migration；
  indexVersion 的"索引成功后更新"随 Tier 3 索引器落地）
- [x] 流式存储写放大修复（UI 40ms 聚合不变，落库降频至 ~240ms；
  中间 sync 不再 touch 会话时间戳，commit 统一落库）+ messageStates LRU
  上限（200，最近使用不逐出）
- [x] 性能基线扩展：启动 10k 消息、流式存储吞吐、侧栏派生计算
  （XCTMeasure，DataFoundationBaselineTests）

**第二批｜接口地基**（ADR-0008 D3）

- [x] ContextBuilder：统一上下文预算（历史截断已落地，保留尾部 + 最后一条
  消息保底；RAG 注入 / 工具结果记账槽位预留）
- [x] IndexEventPublishing：SessionStore → 索引协调的事件发布协议
  （append / update / commit / delete / 导入发布，流式中间写回不发布）
- [x] ToolRegistry / ToolExecutor 协议：工具注册与执行契约（分级 T0~T2，
  进程内注册表已落地；执行器实现随 Tier 2）
- [x] 设置数据模型扩展：命名资料库（名称 / 路径 / 开关 / bookmark）、长时
  推演时长档位、工具开关（SettingsStore + 设置页「本地资料库 / AI 能力」
  分区）
- [x] 路径授权基建：NSOpenPanel 选目录 + security-scoped bookmark 持久化 +
  PathScope 规范化 / symlink 防逃逸包含检查（含"最长存在祖先"解析；
  TCC 行为按目标 macOS 实测）

**验收标准**（ADR-0008 D5）：行为不变（swift test ≥191 全绿）；新增性能
基线；依赖方向单向；每批独立提交、可回滚。逐条可测量验收标准见
[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §4。

### Tier 2｜Rust 骨架与工具链（中低难度，打通即闭环）

- [x] RustCore crate 骨架：staticlib + 最小 C ABI（JSON 出入）+ 手写头文件
- [x] scripts/build-rust-core.sh（cargo → lipo → strip + ABI 符号校验；
  无 cargo 时 cc/ar 降级 stub 库）+ make-app.sh 接入 + CI（rust
  fmt / clippy / test job、test-degraded job、release 双 target）
- [x] SwiftPM：CRustCore target + IndexService 协议 + RustIndexService
  + MockIndexService
- [x] T0 计算器：Rust 表达式求值器（dc_eval_expr），无子进程
- [x] 工具调用循环：function calling 往返 + 轮次上限 + 透明展示
  （依赖 ContextBuilder；先用 Chat Completions 验证，Responses 的 function
  工具随 v4-pro 开放跟进）
- [x] 深度思考 v1：reasoning_effort=max 档位 UI（纯 API 参数过渡方案）

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §5。

### Tier 3｜资料库 RAG（中难度）

- [x] library_index：根目录扫描（规范化 + symlink 包含检查，隐藏 / 二进制 /
  超大 / 白名单外 / 依赖目录跳过）/ 分块（默认 600 token、重叠 120，CJK
  1 字符 ≈ 1 token）/ 增量（path + mtime + contentHash）/ 扩展名白名单
  （RustCore/src/library.rs，T3-1a~e）
- [x] embedding：mock-embeddings 先行落地（确定性哈希向量 + 余弦检索，
  `Embedder` trait 可注入；T3-1a recall@5 ≥ 0.8 校准通过）；candle 本地
  模型与远程 OpenAI 兼容 embedding 预留待接入
- [x] 检索注入 + Source 引用卡片复用（`LibraryRetrievalInjector`：各库
  top-k → 按文件去重 → token 预算裁剪（默认 6k，4~8k 可配）→ system 前缀
  注入；命中文件生成 Source（标题 = 文件名，url = 路径），UI 零新增概念）
- [x] 索引版本化 / rebuild（版本不匹配触发重建；索引文件可整体删除重建；
  取消为操作级标志，取消后重启从断点续跑；一致性校验 = 增量重扫断言）；
  重建分片进度回调待接入（当前为状态展示 + 取消）
- [x] 命名资料库 UI：增删改、启用开关、单库重新索引按钮、索引状态 /
  文件 / 分块数 / 最近索引时间、全局进度与取消（设置页 + LibraryIndexModel）

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §6（T3-1a~e /
  T3-2c / T3-3a~b 已可自动验证；T3-2a 检索 p95 与 T3-2b 断点续跑性能项
  待数据规模基准跑通后按 §9 校准）。

**已知问题（2026-08-01 实测复现，暂不修复，方案登记于此）**：
mock 向量检索区分度差——用真实项目文档作语料跑模糊查询（如「评估我的
项目架构」「分层架构怎么组织的」）时，top-5 命中随机、无关段落分数普遍
偏高（170~365）且彼此接近，相关文档无明显优势。根因：① 128 维哈希桶对
600-token 分块严重饱和（文档向量几乎全桶非零，任意查询与任意文档都有
大量伪共享桶）；② 无词频 / IDF 权重，高频词稀释区分度；③ 无相关性
阈值（score > 0 即进 top-k）；④ 本质是 n-gram 字面重叠而非语义。
修复方案（按性价比排序，实施时以模糊查询评估集替换 T3-1a 的直接词重叠
查询）：
1. 用 TF-IDF / BM25 稀疏检索替换 mock 哈希向量（词元 = 中文单字 + 双字组
   + 英文词，权重 = 词频 × IDF，余弦 / 点积打分；零依赖，消灭哈希桶饱和
   与碰撞噪声，是字面检索的质量上限）
2. 注入器加相关性阈值 + top-k 分数差距校验，低于阈值不注入
3. 中期接 candle 语义 embedding（解决同义词 / 改写等真语义问题）

### Tier 4｜只读文件与脚本沙箱（中高难度，默认关闭）

- [ ] T1 read_file：根目录内只读 + 扩展名白名单 + 大小 / 行数上限 + 按段截断
- [ ] T2 python3 -S 沙箱：seatbelt profile（拒网络 / 拒写盘）+ 超时强杀 +
  输出 / 内存上限 + 环境清空；默认关闭 + 全局开关
- [ ] 工具审计：每次调用（名称 / 参数 / 结果摘要）写入会话并在 UI 展示
- [ ] （可选）FSEvents 增量监听资料库变更

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §7。

### Tier 5｜长时推演模式（高难度，最后做）

- [ ] 深度自检（轻量）：生成后第二遍验证调用，成本约 ×2，独立开关
- [ ] 长时推演循环：规划 → 展开 → 工具验算 → 自评 → 修正 → 综合，
  时间预算驱动（5 / 10 / 20 / 30 分钟或 token 预算）
- [ ] 进度与成本护栏：实时阶段进度 / 发起前费用估算 / 随时停止 /
  部分结果保留
- [ ] 断点续跑：流式中断后保留已完成推演内容
- [ ] 远期：外部 MCP server 暴露（需评估进程约束）、多库混合检索、
  HNSW 升级、深度模式锁定 pro

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §8。

### Tier A｜审计模块（贯穿 Tier 3~5，方案已定稿）

- [x] 方案定稿：ADR-0009（威胁模型 + 7 审计域 + 事件目录 70 种）+
  ACCEPTANCE §11 量化验收（AU-1~AU-21），2026-08-01（**未实现**）
- [x] P1 地基：AuditEvent / AuditDomain / AuditLogging / AuditStore
  （独立 audit.sqlite，追加式）/ AuditRedactor / Sinks / Reporter +
  设置页审计查看器（2026-08-01）
- [x] P1 接入：A 配置（SettingsStore 安全相关 didSet）、B 权限
  （PathScope / bookmark / 注册表自检 / 轮次上限）、C 工具（executeTool）、
  D 存储（迁移 / 降级 / 导入导出 / 索引）四域现成挂点（索引事件随 Tier 3）
- [x] P2 FFI：Rust 计数器 + panic hook（崩溃日志）+ `dc_audit_snapshot` +
  分配 / 泄漏断言；cargo audit / fuzz（cron）/ ASan 进 CI（2026-08-01）
- [ ] P3：read_file / 沙箱门禁审计（随 Tier 4）；哈希链加固（可选）
- [ ] P4：网络 / 长时推演域事件（随 Tier 5）；保留策略自动执行；导出完善
- [x] scale 阈值上调（P1 落地校准：6000 → 7500，原因记录在 check-scale.sh）

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §11（AU-1~AU-21）。

---

## 三、历史 backlog（低优先级）

原 TODO 一~五节（长会话性能记录、UI 改进、Beta 0.2 / 0.3 / 1.0 路线、
工程记录、长期探索）已归档至 [TODO_HISTORY.md](TODO_HISTORY.md)。

低优先级候选（按需从归档捞起、重新评估后再进本表）：

- 键盘快捷键（⌘N / ⌘1~9 / Esc 收面板）与全局热键（如 ⌥Space）
- 1.0 发布：universal 双架构产物（Intel + Apple Silicon，当前 CI 仅
  arm64）+ Developer ID 签名公证 + dmg / Sparkle 自动更新
- 无障碍（VoiceOver、动态字体）、多语言（中 / 英）
- iCloud 同步（隐私取舍，默认关闭）
- 语音输入（macOS 听写 / Whisper API）、多标签页 / 分屏对比回复
- 本地隐私模式（会话加密存储）、面板毛玻璃
