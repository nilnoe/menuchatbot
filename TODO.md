# DeepSeek Chat 开发路线图（TODO）

> 版本状态：Beta 0.3（2026-08-01）
> 本文档是**现行规划**：工程原则 + Rust 核心与 AI 能力路线。
> 历史 TODO（性能记录 / UI 改进 / Beta 0.2~1.0 路线 / 工程记录 / 长期探索）
> 已拆分至 [TODO_HISTORY.md](TODO_HISTORY.md)，**降级为低优先级归档**，
> 以本文档为准。全部文档索引见 [docs/README.md](docs/README.md)。

> **当前状态（2026-08-01）**：测试 191 全绿；分层架构重构与测试模块化
> Phase A 已完成（细节见 TODO_HISTORY.md / CHANGELOG.md）；Rust 核心与
> AI 能力规划定稿（见第二节），纯文档规划，未动代码。
>
> **历史进展存档**：0.2.x 性能里程碑、0.3 功能与 UI 收尾等逐项细节见
> [CHANGELOG.md](CHANGELOG.md) 与 [TODO_HISTORY.md](TODO_HISTORY.md)。
>
> **下一步方向**：按第二节 Tier 1 推进——先数据地基、再接口地基；
> 键盘快捷键 / 全局热键 / 1.0 发布项等原 backlog 已降级至
> TODO_HISTORY.md，按需再捞起。

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

- [ ] SessionStore 拆分 SessionSummary 与消息分页（侧栏不再持有消息正文，
  token 合计列化，消除每行 reduce；同时消除启动全量物化）
- [ ] 消息表派生列：tokenTotal / contentHash / indexVersion（GRDB migration）
- [ ] 流式存储写放大修复（存储降频 + 后台写队列）+ messageStates LRU 上限
- [ ] 性能基线扩展：启动 10k 消息、流式存储吞吐、侧栏渲染不随消息数线性
  变慢（XCTMeasure）

**第二批｜接口地基**（ADR-0008 D3）

- [ ] ContextBuilder：统一上下文预算（历史截断 + RAG 注入 + 工具结果记账），
  禁止各模块自行拼上下文
- [ ] IndexEventPublishing：SessionStore → 索引协调的事件发布协议
- [ ] ToolRegistry / ToolExecutor 协议：工具注册与执行契约（实现随 Tier 2）
- [ ] 设置数据模型扩展：命名资料库列表（名称 / 路径 / 开关）、长时推演时长、
  工具开关（SettingsStore + 设置页）
- [ ] 路径授权基建：NSOpenPanel 选目录 + security-scoped bookmark 持久化 +
  规范化 / symlink 防逃逸的路径包含检查（TCC 行为按目标 macOS 实测）

**验收标准**（ADR-0008 D5）：行为不变（swift test ≥191 全绿）；新增性能
基线；依赖方向单向；每批独立提交、可回滚。逐条可测量验收标准见
[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §4。

### Tier 2｜Rust 骨架与工具链（中低难度，打通即闭环）

- [ ] RustCore crate 骨架：staticlib + 最小 C ABI（JSON 出入）+ 手写头文件
- [ ] scripts/build-rust-core.sh（cargo → lipo → strip）+ make-app.sh 接入
  + CI（fmt / clippy / test / 体积门禁）
- [ ] SwiftPM：CRustCore target + IndexService 协议 + RustIndexService
  + MockIndexService
- [ ] T0 计算器：Rust 表达式求值器（dc_eval_expr），无子进程
- [ ] 工具调用循环：function calling 往返 + 轮次上限 + 透明展示
  （依赖 ContextBuilder；先用 Chat Completions 验证，Responses 的 function
  工具随 v4-pro 开放跟进）
- [ ] 深度思考 v1：reasoning_effort=max 档位 UI（纯 API 参数过渡方案）

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §5。

### Tier 3｜资料库 RAG（中难度）

- [ ] library_index：根目录扫描 / 分块（500~800 token 带重叠）/ 增量
  （mtime + hash）/ 扩展名白名单
- [ ] embedding 本地模型接入（candle；mock-embeddings feature 先行；
  远程 OpenAI 兼容预留）
- [ ] 检索注入 + Source 引用卡片复用（RAG 命中文件显示为参考来源）
- [ ] 索引版本化 / rebuild（进度 + 取消）/ 一致性校验
- [ ] 命名资料库 UI：增删改、启用开关、单库重新索引

**验收**：见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §6。

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

---

## 三、历史 backlog（低优先级）

原 TODO 一~五节（长会话性能记录、UI 改进、Beta 0.2 / 0.3 / 1.0 路线、
工程记录、长期探索）已归档至 [TODO_HISTORY.md](TODO_HISTORY.md)。

低优先级候选（按需从归档捞起、重新评估后再进本表）：

- 键盘快捷键（⌘N / ⌘1~9 / Esc 收面板）与全局热键（如 ⌥Space）
- 1.0 发布：Developer ID 签名公证 + dmg / Sparkle 自动更新
- 无障碍（VoiceOver、动态字体）、多语言（中 / 英）
- iCloud 同步（隐私取舍，默认关闭）
- 语音输入（macOS 听写 / Whisper API）、多标签页 / 分屏对比回复
- 本地隐私模式（会话加密存储）、面板毛玻璃
