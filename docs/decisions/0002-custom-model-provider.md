# ADR-0002：自定义模型供应商（OpenAI 兼容 base_url）

- 状态：已接受（2026-07-31，main）
- 关联：TODO_HISTORY.md「Beta 0.3」、Services/DeepSeekClient.swift、Persistence/SettingsStore.swift

## 背景

Beta 0.3 首个功能：允许用户接入 OpenAI 兼容的自定义模型供应商（自定义 base_url
与模型列表）。ADR-0001 的 D2 曾约定「多供应商需求出现时再抽象网络层」——本功能即
该触发点。

## 决策

### D1：网络层不做全量协议化，只参数化 baseURL + 能力标记

`DeepSeekClient` 保持 struct 不变：init 增加 `baseURL` 参数（默认官方地址），
`chatCompletions` 增加 `isCustomProvider: Bool`。自定义供应商时请求体省略
DeepSeek 专属字段（`thinking` / `reasoning_effort`），`supportsResponses` 恒为
false（不走 Responses API / 联网搜索）。

理由：现有 MockURLProtocol + 回调注入已覆盖全部请求形态；抽象出完整
`APIProviding` 协议只会增加间接层，待真正出现多套请求签名差异时再评估。

### D2：自定义模型归属 Services 目录（ModelCatalog），配置归 SettingsStore

`CustomModel`（id + 展示名）落在 Domain（最内层，SettingsStore 与 ModelCatalog
都可依赖）；`ModelCatalog.all(custom:)` / `info(_:custom:)` 合并内置与自定义模型，
视图与控制器一律经 `SettingsStore.availableModels` / `modelInfo(for:)` 访问，
不直接拼列表。

### D3：能力边界

自定义模型只支持 OpenAI 兼容 Chat Completions 标准字段；思考模式、推理强度、
联网搜索为 DeepSeek 专属能力，对自定义模型禁用并在 UI 说明。

## 后果

**正面**：不改网络层结构即可接入任意 OpenAI 兼容供应商；自定义模型列表持久化
（UserDefaults JSON），导入导出等既有行为不受影响；157 个测试全绿。

**代价**：自定义模型暂不支持思考模式与联网搜索（后续可按模型能力扩展）；
`ModelInfo` 从静态常量变为「内置 + 自定义」两段式目录，调用方需经
`SettingsStore` 计算属性访问。

## 备选方案

- 完整 `APIProviding` 协议：当前仅一套请求签名（+ 一个布尔标记），过度设计，否决。
- 自定义供应商直接改写官方 baseURL 默认值：会把用户配置混入内置常量，语义不清，否决。
