# ADR-0009：审计模块（运行时记录 + 验证纪律 + 报告）

- 状态：已接受（2026-08-01，方案定稿；P1 已实现）
- 关联：[ACCEPTANCE §11](../ACCEPTANCE.md)、TODO「Tier A｜审计模块」、
  ADR-0006（工具审计承诺 D3.4）、ADR-0004（FFI 边界）

## 背景

架构复杂度上升后，安全相关行为（权限授权 / 拒绝、工具调用、FFI 错误、
配置变更、数据迁移）散布在各层且多数**静默**：只有工具调用以
`toolCallsJSON` 躺在会话历史（T2-3c），其余无结构化记录；os_log 仅覆盖
存储错误。用户要求按业界主流规范建立审计模块，内存安全与权限控制是其中
两个审计域，而非全部。

### 威胁模型（审计要防什么、防不住什么）

- 保护目标：**可追溯**——安全事件发生后能回答"发生了什么、何时、在哪个
  会话、被谁触发、结果如何"；**可验证**——审计系统自身的行为可被测试断言
  （先红后绿）。
- 假设对手：同用户权限级的恶意软件可读写本机任意文件（含审计库），因此
  审计**不宣称防提权**；哈希链（P3 可选）防的是应用 bug 与误操作导致的
  静默篡改，不是防恶意软件。
- 隐私底线：审计本地存储、默认 90 天 / 50MB 滚动；API Key、消息全文、
  文件全文**永不落审计**（字段级脱敏，见 D4）。

## 决策

### D1：审计 = 三层、七域

审计模块同时覆盖三层语义：

1. **运行时审计记录**：结构化、追加式的安全事件日志（audit trail）；
2. **安全验证纪律**：把审计验收写进 ACCEPTANCE 与 CI（fuzz / sanitizer /
  依赖扫描 / 泄漏断言），形成可自动执行的审计（assessment）；
3. **报告与处置**：设置页审计查看器 + 导出，支撑人工评审（review）。

审计域（7 类）：

| 域 | 覆盖 | 主要挂点 |
|---|---|---|
| A config | 配置与身份：API Key 生命周期、供应商 / 工具开关、资料库增删、推演时长 | SettingsStore |
| B permission | 权限控制：TCC / bookmark、PathScope 通过拒绝、注册表白名单、轮次上限、确认闸门 | PathScope / SecurityScopedBookmark / ToolRegistry / ChatStreamController |
| C tool | 工具执行：调用、结果、耗时、沙箱门禁、超时 / 截断 | executeTool / T1 / T2 |
| D storage | 数据与存储：迁移、DB 降级、导入导出、索引重建 / 不可用 | SessionStore / RustIndexService |
| E ffi | 内存与 FFI：错误码分布、panic、分配 / 泄漏计数、fuzz / sanitizer 结果 | RustCore ffi.rs / CI |
| F network | 网络与流：请求（脱敏）、失败 / 重试 / 取消、用量记账 | DeepSeekClient / SSEParser |
| G supplyChain | 供应链与构建：cargo audit、ABI 一致性、CI 门禁 | CI / scripts |

### D2：追加式事件模型

```swift
struct AuditEvent {
    var id: UUID            // 单调递增的可排序 id（数据库自增 + UUID 双键）
    var timestamp: Date
    var domain: AuditDomain // config / permission / tool / storage / ffi / network / supplyChain
    var severity: AuditSeverity // info / warning / error / critical
    var category: String    // 事件目录中的稳定标识，如 "permission.denied"
    var message: String     // 已脱敏
    var sessionID: UUID?
    var requestID: String?  // 每次 send 生成，贯穿工具轮次与流式
    var metadataJSON: String? // 结构化字段（工具名 / 耗时 / 错误码 / 路径摘要等）
}
```

约束：
- `AuditStore` 只暴露 insert / query / export，**不存在 update / delete API**
  （NIST AU-9 追加式；由 API 面与测试双重保证）；
- `record` 异步入队（内存队列 + 后台批量写），失败只落 os_log，**不阻塞
  业务**（ASVS V7.3）；
- requestID 在每次 `send` 时生成，工具轮次、流式、用量记录共用同一关联 ID。

事件目录（初版 70 种，随 Tier 3~5 落地扩展，见文末）作为
`docs/decisions/0009-audit-module.md` 附录与 ACCEPTANCE AU-1 的基准。

### D3：独立审计库 audit.sqlite

- 独立于 `sessions.sqlite`（Application Support 下第二个 GRDB 队列，自有
  迁移链 v1 起，WAL 模式）；
- 理由：会话数据有导入导出与未来"清除会话 / 本地隐私模式"，审计记录
  不应随用户数据一起被抹掉；保留策略可独立执行；查询 / 导出与业务库互不
  干扰；
- 保留策略：默认 90 天或 50MB 滚动（先到先清），可配置；清理只删过期行，
  永不触碰窗口内数据；
- 复用 GRDB（项目第一原则：先找库，不造轮子；禁止自写存储层）。

### D4：脱敏（Redactor）

字段级脱敏规则，全部有语料测试：

- API Key 形态（`sk-` 前缀等）永不落审计与导出；
- 消息全文 / 文件全文：只记"已处理（长度 N）"，不记内容；
- 工具参数与文件路径：截断 ≤ 200 字符 + SHA-256 摘要；
- os_log 同步使用 `privacy: .private` 标记，杜绝意外泄漏。

### D5：FFI / 内存安全审计（域 E）

- `RustCore/src/audit.rs`：全局原子计数器（每错误码次数、总调用、
  未释放分配数、panic 计数）+ 有界环形缓冲（最近 N 条 panic / 错误现场）；
- 新 ABI `dc_audit_snapshot(ix, out_json)` 导出快照，沿用 JSON 出入 +
  `dc_free` 所有权约定（ADR-0004 D5）；
- `std::panic::set_hook`：panic 时先写环形缓冲（消息 + 位置）再 abort，
  把"静默崩溃"变成可检索事件（`panic=abort` 决策不变）；
- 所有权配对：`write_out` / `dc_free` 用全局分配计数，FFI 测试断言操作后
  未释放分配数为 0（升级 T2-1c 为自动断言）；
- CI：rust job 加 `cargo audit`；cron fuzz job（`cargo-fuzz` 打
  `dc_eval_expr` / `dc_index_upsert` 输入）；swift test 增加 ASan 任务
  （仅 FFI 集成测试，控制耗时）。

### D6：挂点接入范围

- A：SettingsStore 安全相关 didSet（工具开关、corpora 增删、
  customProviderEnabled、baseURL、推演时长）；API Key 只记"已写入 / 已删除"；
- B：PathScope 拒绝处、bookmark make / resolve（含 stale）、启动注册表
  自检（"无写 / 删工具"从约定变为可审计断言，ADR-0006 D3.1）；
- C：`executeTool` 与轮次上限分支（现成位置），1:1 对账见 AU-9；
- D：迁移成功 / 失败、DB 降级内存库、导入导出、索引 rebuild / unavailable；
- F：DeepSeekClient 请求发起 / 完成 / 失败 / 取消（记 provider / model /
  是否搜索 / 是否思考 / usage，**不记消息体**）；
- Tier 3~5 衔接：RAG 扫描 / rebuild / 命名空间隔离事件；T1 / T2 门禁链
  （扩展名、大小、seatbelt、超时、环境清空）；长时推演的阶段转换与预算 /
  成本事件（T5-2 直接用审计数据断言 ±5%）。

### D7：哈希链加固（P3，可选）

`prev_hash` 列 + Keychain HMAC 做哈希链，检测静默篡改；明确其防御边界
（防应用 bug 与误操作，不防同权限级恶意软件），P1 / P2 不做。

### D8：规模与工程约束

- 预计新增 Swift 900~1300 行；P1 落地时按项目惯例**先测基线再校准**，
  上调 `check-scale.sh` 的 SOURCE_LINE_LIMIT / TEST_LINE_LIMIT 至 7500
  （校准记录：P1 前基线已为 6126 / 6319，超出旧上限 6000；原因与阈值
  一并写入脚本头，2026-08-01）；
- 零新依赖：复用 GRDB / os_log / Security（PROJECT_SPEC §1）；
- 依赖方向：Audit 只依赖 Foundation + GRDB，任何上层不得反向依赖；
  `check-deps.sh` 追加断言；
- 验收：ACCEPTANCE §11 AU-1~AU-21，每条先红后绿、测试命名可回溯编号。

> **P1 落地记录（2026-08-01）**：审计地基与 A/B/C/D 四域接入完成，
> 43 个新测试（共 315 全绿）；设置页查看器可用；P2（FFI 计数器 /
> panic hook / fuzz / cargo audit / ASan）、P3（Tier 4 门禁审计 /
> 哈希链）、P4（网络 / 推演域 / 保留自动执行）待后续 Tier 落地。

## 后果

**正面**：安全事件全程可追溯（AU-2/3 落地）；FFI 与工具边界从"约定"变为
"可断言"；T4-4 / T5-2 有现成数据底座；隐私底线由测试保证。

**代价**：新增约千行代码与一个独立数据库；CI 增加 cargo audit / fuzz /
ASan 三个任务；规模阈值需上调；事件接入点需要各层协作改动。

## 备选方案

- 审计事件并入 sessions.sqlite：实现省事，但随"清会话"一起丢失，且
  导入导出会污染审计记录，否决。
- 全部走 os_log 不落库：无结构化查询 / 导出 / 保留策略，无法支撑
  AU-9 / AU-11 与数据对账，否决。
- 引入第三方审计框架（如 OSLog 系统化 / 商业 SDK）：当前体量无成熟
  SwiftPM 方案，且违背"纯原生、无新依赖"约束，否决。

---

## 附录：事件目录（初版 70 种）

### A config（11）

config.apiKeyWritten / config.apiKeyDeleted / config.providerEnabledChanged /
config.baseURLChanged / config.modelChanged / config.toolToggleChanged /
config.corpusAdded / config.corpusRemoved / config.corpusToggled /
config.deliberationDurationChanged / config.systemPromptChanged

### B permission（10）

permission.corpusAuthorized / permission.corpusRestored /
permission.bookmarkStale / permission.pathContained / permission.pathDenied /
permission.registrySelfCheckPassed / permission.registryViolation /
permission.roundLimitEnforced / permission.confirmGateShown /
permission.confirmGateDenied

### C tool（12）

tool.executionStart / tool.executionSuccess / tool.executionFailed /
tool.executionTimedOut / tool.executionCancelled / tool.notRegistered /
tool.readFileExtensionRejected / tool.readFileSizeTruncated /
tool.sandboxProfileApplied / tool.sandboxNetworkDenied /
tool.sandboxWriteDenied / tool.sandboxEnvCleared

### D storage（11）

storage.migrationApplied / storage.migrationFailed / storage.dbFallbackToMemory /
storage.exportStarted / storage.exportFinished / storage.importStarted /
storage.importFinished / storage.sessionDeleted / storage.indexRebuildStarted /
storage.indexRebuildFinished / storage.indexUnavailable

### E ffi + supplyChain（7）

ffi.called / ffi.error / ffi.panic / ffi.leakDetected / ffi.snapshotCollected /
supplyChain.cargoAuditFailed / supplyChain.abiCheckFailed

### F network（9）

network.requestStarted / network.requestFinished / network.requestFailed /
network.requestCancelled / network.retryStarted / network.sseParseError /
network.usageRecorded / network.searchTriggered / network.searchSourcesReturned

### G deliberation（Tier 5，10；domain 归 network）

deliberation.started / deliberation.phaseChanged / deliberation.budgetExceeded /
deliberation.costEstimated / deliberation.stopped / deliberation.resumed /
deliberation.verifyPassed / deliberation.verifyFailed /
deliberation.costGuarded / deliberation.partialKept

> 注：事件 `domain` 字段始终按 D1 的 7 域归类（deliberation.* 归
> `network` 域，supplyChain 归 `supplyChain` 域）；附录的 A~G 分组
> 仅为阅读方便。
