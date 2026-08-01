import Foundation

/// 应用级统一常量：bundle id、存储目录、设置键、窗口名称等。
///
/// 单一入口，避免字符串散落各处；改动时只动此处。
enum AppConfiguration {
    /// 应用 Bundle 标识（Keychain service、日志 subsystem、存储目录共用）。
    static let bundleIdentifier = "com.deepseek.chat"

    /// Application Support 下的应用目录名。
    static let appSupportDirectoryName = bundleIdentifier

    /// Application Support 下应用数据目录（会话库 / 审计库共用）。
    static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    /// 索引落盘根目录（Tier 3：每资料库一个子目录，派生数据可整体删除重建）。
    static var indexDirectory: URL {
        appSupportDirectory.appendingPathComponent("index", isDirectory: true)
    }

    /// 主面板窗口 frame autosave 名称。
    static let panelAutosaveName = "mainPanelV2"

    /// 默认（官方）API 地址；启用自定义供应商后可覆盖。
    static let defaultAPIBaseURL = "https://api.deepseek.com"

    /// 钥匙串中 API Key 的账户名。
    static let keychainAPIKeyAccount = "apiKey"

    /// UserDefaults 设置键（与历史版本保持一致，勿改名）。
    enum SettingsKey {
        static let model = "model"
        static let thinking = "thinking"
        static let effort = "effort"
        static let webSearch = "webSearch"
        static let systemPrompt = "systemPrompt"
        static let temperature = "temperature"
        static let customProviderEnabled = "customProviderEnabled"
        static let customBaseURL = "customBaseURL"
        static let customModels = "customModels"
        static let windowSizePreset = "windowSizePreset"
        static let corpora = "corpora"
        static let deliberationDuration = "deliberationDuration"
        static let toolCalculatorEnabled = "toolCalculatorEnabled"
        static let toolReadFileEnabled = "toolReadFileEnabled"
        static let toolPythonEnabled = "toolPythonEnabled"
    }

    /// 工具调用循环轮次上限（ADR-0006 D3：每轮对话工具调用 ≤ N 次）。
    static let defaultMaxToolRounds = 3

    /// RAG 注入 token 预算（T3-3b：ADR-0005 D4 建议 4~8k，可配置）。
    static let ragTokenBudget = 6_000
    /// 每资料库检索 top-k 块数（按文件去重后参与预算裁剪）。
    static let ragTopKPerCorpus = 4
}
