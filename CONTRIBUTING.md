# 贡献指南

感谢你愿意参与 DeepSeek Chat 的开发。请先读完
[PROJECT_SPEC.md](PROJECT_SPEC.md)（工程规范）再动手。

全部开发文档的入口见 [docs/README.md](docs/README.md)（文档地图）。

## 第一原则

> **尽可能复用开源库的代码，不要自己造轮子。**

任何新功能先找成熟开源库或系统框架；找不到才允许自研，且必须在代码注释里写明
"为什么不用库"。解析、网络、存储、渲染、格式处理等通用能力一律禁止自研。

## 本地开发

```bash
swift build        # 编译
swift test         # 跑全部测试（含性能基线）
swift-format lint --recursive --strict Sources Tests   # 代码规范检查（与 CI 一致）
./scripts/check-scale.sh         # 规模检查（防膨胀，与 CI 一致）
./scripts/make-app.sh                          # 打包 .app
```

测试代码按层组织（镜像 `Sources/`），目录约定、命名规范与共享 mock /
测试脚手架的「接口手册」见 [docs/TESTING.md](docs/TESTING.md)；按类只跑部分
测试可用 `swift test --filter 类名`。

## 提 PR 前的检查清单

- [ ] `swift build` 无警告
- [ ] `swift test` 全绿（新增逻辑必须带单测）
- [ ] `swift-format lint --recursive --strict Sources Tests` 零违规
- [ ] `./scripts/check-scale.sh` 通过（源码 / 测试总量与单文件大小上限）
- [ ] 新功能优先复用开源库，并在 PR 描述说明选型
- [ ] 破坏性改动（如存储 schema）走 GRDB 迁移，并同步更新 TODO（历史条目
  进 TODO_HISTORY）/ CHANGELOG

## 分支与提交

- 从 `main` 切分支开发，PR 合并前保持可构建、可测试。
- 提交信息用简洁的中文或英文陈述式，如 `feat: 会话导出 JSON 备份`。

## Issue / PR 模板

新建 Issue / PR 时使用仓库自带的模板（`.github/` 下），方便快速对齐上下文。
