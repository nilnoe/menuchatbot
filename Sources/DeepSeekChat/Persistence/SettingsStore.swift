import Combine
import Foundation

final class SettingsStore: ObservableObject {
    @Published var model: String {
        didSet { defaults.set(model, forKey: AppConfiguration.SettingsKey.model) }
    }
    @Published var thinking: Bool {
        didSet { defaults.set(thinking, forKey: AppConfiguration.SettingsKey.thinking) }
    }
    @Published var effort: Effort {
        didSet { defaults.set(effort.rawValue, forKey: AppConfiguration.SettingsKey.effort) }
    }
    @Published var webSearch: Bool {
        didSet { defaults.set(webSearch, forKey: AppConfiguration.SettingsKey.webSearch) }
    }
    /// 自定义系统提示词（System Prompt）。空字符串 = 使用模型默认。
    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: AppConfiguration.SettingsKey.systemPrompt) }
    }
    /// temperature（0~2）；nil = 跟随模型默认，不随请求发送。
    @Published var temperature: Double? {
        didSet {
            if let temperature {
                defaults.set(temperature, forKey: AppConfiguration.SettingsKey.temperature)
            } else {
                defaults.removeObject(forKey: AppConfiguration.SettingsKey.temperature)
            }
        }
    }
    @Published var apiKey: String {
        didSet {
            if keychainSaveDelay == .zero {
                persistKey(value: apiKey)
            } else {
                keychainSaveTask?.cancel()
                let value = apiKey
                let delay = keychainSaveDelay
                // Keychain 写入可能阻塞，防抖后在后台线程执行
                keychainSaveTask = Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.persistKey(value: value)
                }
            }
        }
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStoring
    private let keychainSaveDelay: Duration
    private var keychainSaveTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore.shared,
        keychainSaveDelay: Duration = .milliseconds(600)
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.keychainSaveDelay = keychainSaveDelay
        let savedModel =
            defaults.string(forKey: AppConfiguration.SettingsKey.model) ?? "deepseek-v4-flash"
        model =
            savedModel == "deepseek-chat" || savedModel == "deepseek-reasoner"
            ? "deepseek-v4-flash"
            : savedModel
        thinking = defaults.object(forKey: AppConfiguration.SettingsKey.thinking) as? Bool ?? true
        effort =
            Effort(rawValue: defaults.string(forKey: AppConfiguration.SettingsKey.effort) ?? "")
            ?? .high
        webSearch = defaults.bool(forKey: AppConfiguration.SettingsKey.webSearch)
        systemPrompt = defaults.string(forKey: AppConfiguration.SettingsKey.systemPrompt) ?? ""
        if defaults.object(forKey: AppConfiguration.SettingsKey.temperature) != nil {
            temperature = defaults.double(forKey: AppConfiguration.SettingsKey.temperature)
        } else {
            temperature = nil
        }
        apiKey = keychain.read(account: AppConfiguration.keychainAPIKeyAccount) ?? ""
    }

    var keyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persistKey(value: String) {
        if value.isEmpty {
            keychain.delete(account: AppConfiguration.keychainAPIKeyAccount)
        } else {
            keychain.write(account: AppConfiguration.keychainAPIKeyAccount, value: value)
        }
    }
}
