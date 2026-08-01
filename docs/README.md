# 文档地图（Documentation Index）

> 本文档是 DeepSeek Chat 全部文档的入口与索引。按「你想做什么」找文档；
> 每份文档标注状态，避免把历史记录误当现行规范。

## 快速入口

| 我想… | 文档 |
|---|---|
| 了解项目、快速开始使用 | [README](../README.md) |
| 参与开发前必读（提 PR 流程） | [CONTRIBUTING](../CONTRIBUTING.md) |
| 工程规范 / 架构约束 / 依赖规则 | [PROJECT_SPEC](../PROJECT_SPEC.md) |
| 测试怎么组织、支持 API 手册 | [TESTING](TESTING.md) |
| 测试模块化规划（Phase A / B / C） | [TESTING_ROADMAP](TESTING_ROADMAP.md) |
| 发布流程 | [RELEASING](RELEASING.md) |
| macOS SwiftUI 踩坑经验 | [PITFALLS](PITFALLS.md) |
| 版本变更历史 | [CHANGELOG](../CHANGELOG.md) |
| 开发路线图 / 待办 | [TODO](../TODO.md) |
| 架构决策记录（ADR） | [decisions](decisions/) |

## 文档分类与状态

### 用户向

- [README](../README.md) —— 功能、安装、使用、FAQ（活跃）。

### 开发者向（活跃，以最新提交为准）

- [CONTRIBUTING](../CONTRIBUTING.md) —— 贡献流程与检查清单。
- [PROJECT_SPEC](../PROJECT_SPEC.md) —— 工程原则、架构约束、规范。
- [TESTING](TESTING.md) —— 测试目录约定、命名规范、支持 API 手册。
- [TESTING_ROADMAP](TESTING_ROADMAP.md) —— 测试模块化分阶段规划与触发条件。
- [RELEASING](RELEASING.md) —— 发版步骤。
- [PITFALLS](PITFALLS.md) —— macOS SwiftUI 交互踩坑记录（持续补充）。

### 决策记录（已接受）

- [decisions/README.md](decisions/README.md) —— ADR 索引（0001~0003）。

### 历史记录（归档，仅参考，不随现状改写）

- [REFACTORING](REFACTORING.md) —— 2026-07 分层架构重构的分步过程（已完成）。
- [CHANGELOG](../CHANGELOG.md) 各历史版本条目。

## 维护规则

- 新增文档：按分类放入 `docs/`，登记到本索引与 README「文档地图」。
- 改动代码 / 测试时同步更新受影响文档；历史记录不改写，新状态用新条目说明。
- 链接：文档间用相对链接；引用仓库根文件用 `../`。
