# ADR-0003：测试代码模块化（目录镜像 + 支持 API 层）

- 状态：已接受（2026-08-01，refactor/test-modularization）
- 关联：docs/TESTING.md、CONTRIBUTING.md

## 背景

测试规模已达 191 个、约 4200 行，仍平铺在单个 test target 根目录：
`TestSupport.swift`（173 行）混装 mock 与工厂，`SessionStoreTests`（739 行）
等大文件横跨多个行为面，导航与 review 成本上升。需要让测试代码与生产代码
一样按层组织、可长期演进。

## 决策

### D1：测试目录镜像源码分层

`Tests/DeepSeekChatTests/` 下按 `App / Domain / Services / Persistence /
Streaming / Views / Performance / Support` 分目录，与 `Sources` 一一对应。
单一 test target 不变，SwiftPM 不感知目录，纯组织性改动。

### D2：按行为面拆分大测试文件

一个测试类只测一个行为面；单文件接近 300 行即按 MARK 拆分。本轮
`SessionStoreTests` → 5 个、`DeepSeekClientTests` → 3 个、
`SSEParserTests` → 4 个、`SettingsStoreTests` → 2 个，断言一行不改。

### D3：Support 接口层 + 接口手册

共享 mock / 工厂 / 脚手架收敛到 `Support/`，测试夹具抽为 Harness
（`SessionStoreHarness` / `SettingsStoreHarness` 封装临时目录、UserDefaults
套件与清理）。`docs/TESTING.md` §3 作为「测试支持 API 接口手册」。
单 target 内编译器不强制访问控制，接口靠文档 + 约定维护，为 Plan B 预置
`public` 化清单。

### D4：本轮不引入多 test target、不拆生产模块

保持单一 SwiftPM target 与单一 test target。行为不变，191 个测试为基线；
多 target / TestSupport 模块化升级触发条件见 TESTING.md §7。

## 后果

- 正面：导航成本下降、review 粒度变小、支持代码单一来源、写测试有手册可查。
- 代价：XCTest 类各自持有少量 setUp 样板；编译隔离与 CI 分片暂未获得。
- 演进：规模达到触发条件时按 TESTING.md §7 升级，接口清单已就绪。
