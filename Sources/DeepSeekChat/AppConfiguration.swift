import Foundation

/// 应用级统一常量：bundle id、存储目录、设置键、窗口名称等。
///
/// 单一入口，避免字符串散落各处；改动时只动此处。
enum AppConfiguration {
    /// 应用 Bundle 标识（Keychain service、日志 subsystem、存储目录共用）。
    static let bundleIdentifier = "com.deepseek.chat"

    /// Application Support 下的应用目录名。
    static let appSupportDirectoryName = bundleIdentifier

    /// 主面板窗口 frame autosave 名称。
    static let panelAutosaveName = "mainPanelV2"

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
    }
}
