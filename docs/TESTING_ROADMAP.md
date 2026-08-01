# 测试模块化路线图（TODO）

> 分支：`refactor/test-modularization`（从 `main` 0a50d82 切出）
> 状态：**阶段 A 已完成**（2026-08-01）；阶段 B / C 待触发，触发条件见 §5
> 基线：模块化前 `swift test` 191 个测试全部通过；阶段 A 完成后仍为 **191** 个全部通过

本文档是测试代码模块化的分步规划。每阶段遵循「小步、行为不变、测试护航」
铁律：完成一个阶段、跑绿一次，再进入下一阶段。日常测试约定（目录、命名、
支持 API 手册）见 [docs/TESTING.md](TESTING.md)；关键决策记录见
[docs/decisions/0003-test-modularization.md](decisions/0003-test-modularization.md)。

---

## 0. 遵循的项目规范

与 [CONTRIBUTING.md](../CONTRIBUTING.md) 一致：

1. **质量门**（每阶段验收均含）：
   - `swift build` 无警告
   - `swift test` 全绿（重构不得降低测试数量）
   - `swift format lint --recursive --strict Sources Tests` 零违规
2. **行为不变**：只搬位置、不改断言；拆分与模块化不动被测代码逻辑。
3. **不引入新依赖**：模块化只用 SwiftPM 原生能力。
4. **文档同步**：改动同步更新 TESTING.md、本文件、README、CHANGELOG、TODO。
5. **提交风格**：按 CONTRIBUTING 使用陈述式提交，`refactor: ` / `docs: `
   前缀，每阶段独立成提交，便于 review 与回滚。

---

## 1. 遵循的业界实践

| 实践 | 出处 / 依据 | 在本项目的落点 |
|---|---|---|
| 测试目录镜像源码 | Apple / Swift 社区惯例 | `Tests/` 下与 `Sources/` 同构分目录 |
| 测试类单一职责（按行为面） | 《重构》/ SOLID | 大测试文件按 MARK 拆成 `<类型><行为>Tests` |
| 测试支持独立模块 | 大型 Swift 开源项目惯例 | 阶段 A 收敛为 `Support/` 目录；阶段 B `public` 化 |
| 测试金字塔 | 《软件测试的艺术》/ 业界共识 | 单测为主，视图冒烟少量，性能基线独立 |
| 接口手册先行 | API 文档惯例 | TESTING.md §3 手册 = 阶段 B `public` 接口的候选清单 |
| ADR 决策记录 | 项目既有惯例 | ADR-0003 记录模块化决策与触发条件 |

---

## 2. 现状与问题

### 2.1 阶段 A 之前（2026-08-01 起点）

- 单 test target、21 个文件约 4200 行全部平铺在 `Tests/DeepSeekChatTests/` 根目录，
  与生产代码分层（App / Domain / Services / Persistence / Streaming / Views）
  不对应。
- `TestSupport.swift`（173 行）混装 mock、URLProtocol、工厂方法，新增测试要
  先翻源码找可复用的东西。
- 大文件横跨多个行为面：`SessionStoreTests` 739 行、`DeepSeekClientTests` 518 行、
  `SSEParserTests` 390 行、`ChatViewRenderTests` 386 行。
- CI 单一 `swift test` 全量跑，无分层、无分片。

### 2.2 阶段 A 之后（现状）

- 36 个文件按 8 个目录组织（App / Domain / Services / Persistence / Streaming /
  Views / Performance / Support），找测试的路径与找代码一致。
- 大文件已按行为面拆分，断言一行未改。
- 共享支持收敛为 `Support/` 接口层：Harness 封装临时目录 / UserDefaults 套件 /
  清理；TESTING.md §3 提供接口手册。
- 剩余问题：单 target 内无法做编译隔离与 CI 分片；支持接口靠「文档 + 约定」
  维护，编译器不强制（阶段 B 解决）。

---

## 3. 目标架构（最终形态）

阶段 B 完成后，测试侧的目标结构：

```
Tests/
├─ DeepSeekChatTestSupport/       # 库 target（不跑测试），Support API public 化
├─ DeepSeekChatCoreTests/         # Domain / Services / Persistence / Streaming 单测
├─ DeepSeekChatViewTests/         # Views / App 渲染与布局冒烟
└─ DeepSeekChatPerformanceTests/  # 性能基线（可单独跑，不拖慢常规开发）
```

依赖方向：三个测试 target 依赖 `DeepSeekChatTestSupport`；全部依赖生产 target。
阶段 B 不改变生产 target 结构；生产代码拆库（阶段 C）是独立决策。

---

## 4. 分步计划

### Phase A：目录镜像 + 行为面拆分 + Support 接口层（已完成）

- **目标**：测试代码可导航、可读、支持代码单一来源。
- **动作**：
  - [x] `Tests/` 按 `Sources/` 分层建目录，16 个未拆分文件搬移
    （`git mv`，历史可追溯）
  - [x] 大文件按行为面拆分：`SessionStoreTests` 739 行 → 5 个、
    `DeepSeekClientTests` → 3 个、`SSEParserTests` → 4 个、
    `SettingsStoreTests` → 2 个（断言不改）
  - [x] `TestSupport.swift` 拆为 `Support/` 6 个文件并补文档注释：
    CallbackRecorder / MockKeychain / MockURLProtocol（含延迟流式）/
    URLSessionFactory / SessionStoreHarness / SettingsStoreHarness
  - [x] 新增 docs/TESTING.md（目录约定、命名规范、支持 API 接口手册、
    新增测试流程、质量门）
  - [x] ADR-0003 记录决策；README / CHANGELOG / CONTRIBUTING / TODO 同步
- **验收**：三项质量门全过；191 个测试全绿（与基线一致，数量不减）。
- **风险**：低——不碰 Package.swift 与 CI，纯组织性改动；已实测通过。

### Phase B：多测试 target + TestSupport 独立模块（待触发）

- **目标**：编译隔离、CI 分层 / 分片、接口由编译器强制。
- **动作**：
  - [ ] `Package.swift` 新增 `DeepSeekChatTestSupport` 库 target；
    新增 Core / View / Performance 三个测试 target 并调整依赖
  - [ ] `Support/` 内容迁入 TestSupport 模块，按 TESTING.md §3 手册逐项
    `public` 化并保持文档同步
  - [ ] 现有测试文件按归属迁入各 target，统一 import
  - [ ] CI 分片：lint / core / views / performance 独立 job（或
    `swift test --filter` 分组跑），性能基线不再拖慢常规反馈
  - [ ] 核对 TESTING.md §3 手册与 `public` 接口一一对应
- **验收**：行为不变、测试数量不减；每个 target 可单独跑绿；CI 分层生效。
- **风险**：中——动 Package.swift 与全部 import；需在阶段 A 结构稳定后
  单独成阶段执行，不与其他改动混做。

### Phase C：生产代码拆库（明确暂不做）

- **内容**：`DeepSeekChat` 拆为 `DeepSeekChatCore` 库 + 薄可执行壳，
  测试直接依赖库。
- **为什么不做**：这是架构重构而非测试重构；当前源码约 3.5k 行、单 target
  可行，阶段 B 已能解决测试侧全部痛点。
- **再评估条件**（满足任一）：源码超约 10k 行；出现可独立复用的模块
  （如未来插件 / 其他客户端）；编译时间成为实际瓶颈。
- **注意**：若启动，需单独 ADR，并同步 App 入口、`scripts/make-app.sh`、
  README、发布流程。

---

## 5. 触发条件与决策流程

- **启动 Phase B**（满足任一，且由维护者确认）：
  1. 全量 `swift test` 超过约 5 分钟；
  2. 单 test target 测试文件超过约 60 个；
  3. 需要按层设置不同门禁（如性能基线单独卡阈值）。
- **启动 Phase C**：见 §4 Phase C 再评估条件；必须先写 ADR，不与 B 混做。
- 决策流程：触发条件满足 → 在本路线图勾选「待触发 → 进行中」→ 按该阶段
  动作清单执行 → 过质量门 → 独立提交。

---

## 6. 非目标（所有阶段）

- 不新增测试逻辑、不改既有断言（只搬移 / 拆分 / 模块化）。
- 阶段 A / B 不动 `Sources/` 生产代码。
- 不引入新依赖、不换测试框架（保持 XCTest）。
- 阶段 C 默认不做，除非 §5 触发条件满足并另行 ADR。

---

## 7. 完成定义（Phase A 已完成）

- [x] 16 个测试文件按层搬移、5 个原文件拆分删除、Support 接口层就位
- [x] `swift build` 无警告、`swift test` 191 全绿、format lint 零违规
- [x] docs/TESTING.md + ADR-0003 落盘，README / CHANGELOG / CONTRIBUTING / TODO 同步
- [ ] Phase B 勾选项（待触发，见 §5）
