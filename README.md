# MenuChatBot（DeepSeek Chat）

> **AI 项目**：一个完全由 DeepSeek 大模型驱动的原生 macOS 菜单栏聊天应用。
>
> 当前版本：**Beta 0.3** · 纯 Swift / SwiftUI 实现，无 Web 框架、无 WebView、无运行时服务进程。
> 版本更迭与开发经验见 [CHANGELOG.md](CHANGELOG.md)。

点击菜单栏图标即可呼出聊天面板，随时问 AI、联网搜索、管理多个会话——像系统自带工具一样轻快。

---

## 它是什么？

MenuChatBot 是一个常驻在 macOS 菜单栏的 AI 聊天应用：

- 不占 Dock、不常驻后台窗口，需要时点击菜单栏图标呼出，点外部自动收起
- 对话由 **DeepSeek AI 模型**（`deepseek-v4-flash` / `deepseek-v4-pro`）驱动，支持思考模式与联网搜索
- 整个应用是**纯原生 Swift 编写**，安装包不到 1MB，常驻内存约几十 MB，启动即用

## 功能特性

| 功能 | 说明 |
|---|---|
| 菜单栏常驻 | 不占 Dock；左键点击呼出/收起，右键菜单可切换或退出 |
| 流式回复 | 回答逐字显示，可随时停止生成 |
| 思考模式 | 开启后模型先推理再回答，推理过程可折叠查看；支持低 / 高 / Max 三档强度 |
| 联网搜索 | 回答前实时联网（服务端 `web_search`），附参考来源链接 |
| 多会话管理 | 新建 / 切换 / 重命名 / 删除，自动持久化，重启不丢失 |
| 会话导入 / 导出 | 全量 JSON 备份与恢复，或单个会话导出分享 |
| Markdown 渲染 | 标题、列表、代码块、链接等常见格式 |
| 代码高亮 | 代码块支持 185+ 语言语法高亮（highlight.js），语言标签 + 一键复制 |
| 对话设置 | 自定义 System Prompt、temperature（0~2）随机性调节、API Key 测试连接 |
| 自定义模型供应商 | 设置页接入任意 OpenAI 兼容 API（自定义 base_url 与模型列表），
  自定义模型自动省略 DeepSeek 专属参数 |
| Token 用量与费用估算 | 每条回复显示输入 / 输出 / 缓存命中用量与费用估算，
  侧栏会话行累计展示 |
| API Key 安全存储 | 存于 macOS 钥匙串（Keychain），不上传、不写入代码 |
| 窗口体验 | 统一系统表面风格；设置页可选 紧凑 70% / 标准 85% / 铺满 93%
  三档窗口大小（每次启动按档位生效），可缩放、可拖动 |

## 环境要求

- macOS 14 及以上（Apple Silicon / Intel 均可）
- 安装 Xcode 命令行工具（终端执行 `xcode-select --install`）
- 一个 [DeepSeek 开放平台](https://platform.deepseek.com) 的 API Key

## 新手快速开始

### 第一步：构建应用

```bash
# 克隆仓库
git clone git@github.com:nilnoe/menuchatbot.git
cd menuchatbot

# 一键构建（编译 + 生成 .app + 本地签名）
./scripts/make-app.sh
```

构建完成后打开应用：

```bash
open "dist/DeepSeek Chat.app"
```

> 💡 如果 macOS 提示"无法验证开发者"，因为 Beta 版未签名公证：右键点击应用 → **打开**，确认一次即可。

### 第二步：获取 API Key

1. 打开 [platform.deepseek.com](https://platform.deepseek.com) 并注册
2. 进入「API Keys」页面，创建一个 Key（形如 `sk-xxxxxxxx`）
3. 这是你调用 AI 的"钥匙"，按量计费，请勿泄露

### 第三步：配置并开始对话

1. 点击菜单栏的对话气泡图标呼出面板
2. 左下角点「设置 API Key」，粘贴你的 Key（存在钥匙串里）
3. 回到聊天页，输入问题，回车发送
4. 试试侧边栏的「思考模式」「联网搜索」开关

## 开发调试

```bash
swift build       # 编译开发版（.build/debug/DeepSeekChat）
swift test        # 运行 185 个单元测试（含性能基线）
.build/debug/DeepSeekChat   # 启动开发版
```

## 项目结构

```
menuchatbot/
├── Package.swift              # SwiftPM 工程定义（含测试 target）
├── scripts/make-app.sh        # 一键构建脚本（编译 + 打包 .app）
├── Sources/DeepSeekChat/
│   ├── App/                   # 入口 + 装配（AppDelegate）、面板 /
│   │                         #   状态栏图标 / 主菜单控制器
│   ├── Domain/                # 领域模型：会话 / 消息 / 来源 / 导入导出 DTO
│   ├── Services/              # 网络层（DeepSeekClient / SSEParser）、
│   │                         #   ModelCatalog / MarkdownCache / ConnectionChecker
│   ├── Persistence/           # SessionStore（仓储）、GRDB 记录、
│   │                         #   SettingsStore / KeychainStore / 迁移
│   ├── Streaming/             # MessageState（流式状态 + 增量缓冲）、
│   │                         #   ChatStreamController（流式编排）
│   ├── Views/                 # SwiftUI 界面（纯展示）
│   ├── DeepSeekChatApp.swift  # @main 入口
│   └── AppConfiguration.swift # 应用级常量单一入口
└── Tests/DeepSeekChatTests/   # 191 个单元测试
```

分层规则（Views → Streaming → Services / Persistence → Domain）与
接口隔离约定见 [PROJECT_SPEC.md](PROJECT_SPEC.md) §3.1；重构过程与
决策记录见 [docs/REFACTORING.md](docs/REFACTORING.md) 与
[docs/decisions](docs/decisions/)；macOS SwiftUI 交互踩坑记录见
[docs/PITFALLS.md](docs/PITFALLS.md)。

## 数据与安全

- **API Key**：macOS 钥匙串（服务 `com.deepseek.chat`），设置后请求由本机应用直接发出，不经任何第三方代理
- **会话数据**：本地 SQLite（GRDB，WAL 模式，旧 `sessions.json` 启动时一次性
  迁移），路径 `~/Library/Application Support/com.deepseek.chat/`，不上传
- **AI 内容**：所有回答由 DeepSeek 模型生成，可能有误，重要信息请自行核实

## 常见问题（FAQ）

**Q：粘贴 API Key 没反应？**
应用内置了标准「编辑」菜单，Cmd+V / 右键粘贴均可用；若旧实例未退出，请先右键菜单栏图标 → 退出再重新打开。

**Q：联网搜索是灰色的？**
联网搜索走 DeepSeek Responses API，目前仅 `deepseek-v4-flash` 支持；`deepseek-v4-pro` 支持预计 2026 年 8 月初开放。

**Q：为什么点击菜单栏图标没反应？**
面板默认隐藏，点击图标呼出；若已呼出则点击收起。右键图标 → 「显示面板」也能呼出。

**Q：侧栏的置顶 / 重命名按钮点了没反应？**
已知问题（暂未解决）：会话行的快捷按钮在部分机器上点击无响应，已登记在
[TODO.md](TODO.md) 顶部「已知未解决」与 CHANGELOG；可先用右键菜单完成
置顶 / 重命名 / 删除。

**Q：应用是 AI 项目，和 DeepSeek 官方有什么关系？**
本项目是社区开发的第三方客户端，使用 DeepSeek 开放 API，与 DeepSeek 官方无关联。

## 许可证

[MIT](LICENSE) © 2026 nilnoe
