import Combine
import Foundation

final class SettingsStore: ObservableObject {
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: AppConfiguration.SettingsKey.model)
            audit.record(
                domain: .config,
                category: AuditCategory.modelChanged,
                message: "模型切换",
                metadata: ["model": model]
            )
        }
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
    /// 是否启用自定义模型供应商（OpenAI 兼容 base_url）。
    @Published var customProviderEnabled: Bool {
        didSet {
            defaults.set(
                customProviderEnabled,
                forKey: AppConfiguration.SettingsKey.customProviderEnabled
            )
            audit.record(
                domain: .config,
                category: AuditCategory.providerEnabledChanged,
                message: customProviderEnabled ? "自定义供应商已启用" : "自定义供应商已停用",
                metadata: ["enabled": String(customProviderEnabled)]
            )
            // 关闭供应商后，若当前选中的是自定义模型，回退到内置默认模型，
            // 避免拿自定义模型 ID 请求官方接口。
            if !customProviderEnabled, !ModelCatalog.builtin.contains(where: { $0.id == model }) {
                model = "deepseek-v4-flash"
            }
        }
    }
    /// 自定义供应商 API 地址（如 `https://api.openai.com/v1`）；空值回退官方地址。
    @Published var customBaseURL: String {
        didSet {
            defaults.set(customBaseURL, forKey: AppConfiguration.SettingsKey.customBaseURL)
        }
    }
    /// 自定义模型列表（OpenAI 兼容模型 ID + 展示名）。
    @Published var customModels: [CustomModel] {
        didSet {
            if let data = try? JSONEncoder().encode(customModels) {
                defaults.set(data, forKey: AppConfiguration.SettingsKey.customModels)
            }
            // 删除当前选中的自定义模型时回退到内置默认模型。
            if !availableModels.contains(where: { $0.id == model }) {
                model = "deepseek-v4-flash"
            }
        }
    }
    /// 窗口大小档位（占可见区域比例）。默认「铺满 93%」，与 0.2.x 默认一致。
    @Published var windowSizePreset: WindowSizePreset {
        didSet {
            defaults.set(
                windowSizePreset.rawValue,
                forKey: AppConfiguration.SettingsKey.windowSizePreset
            )
        }
    }
    /// 命名资料库列表（名称 / 路径 / 开关 / 授权 bookmark）。
    @Published var corpora: [LibraryCorpus] {
        didSet {
            if let data = try? JSONEncoder().encode(corpora) {
                defaults.set(data, forKey: AppConfiguration.SettingsKey.corpora)
            }
            auditCorpusChanges(from: oldValue, to: corpora)
        }
    }
    /// 长时推演时长档位（Tier 5 使用；默认 5 分钟）。
    @Published var deliberationDuration: DeliberationDuration {
        didSet {
            defaults.set(
                deliberationDuration.rawValue,
                forKey: AppConfiguration.SettingsKey.deliberationDuration
            )
            audit.record(
                domain: .config,
                category: AuditCategory.deliberationDurationChanged,
                message: "长时推演时长变更",
                metadata: ["minutes": String(deliberationDuration.minutes)]
            )
        }
    }
    /// 工具开关（ADR-0006 D2：T2 python 默认关闭；T1 read_file 默认关闭，
    /// 待 Tier 4 沙箱与授权就绪后由用户开启）。
    @Published var toolCalculatorEnabled: Bool {
        didSet {
            defaults.set(
                toolCalculatorEnabled,
                forKey: AppConfiguration.SettingsKey.toolCalculatorEnabled
            )
            recordToolToggle("calculator", enabled: toolCalculatorEnabled)
        }
    }
    @Published var toolReadFileEnabled: Bool {
        didSet {
            defaults.set(
                toolReadFileEnabled,
                forKey: AppConfiguration.SettingsKey.toolReadFileEnabled
            )
            recordToolToggle("readFile", enabled: toolReadFileEnabled)
        }
    }
    @Published var toolPythonEnabled: Bool {
        didSet {
            defaults.set(
                toolPythonEnabled,
                forKey: AppConfiguration.SettingsKey.toolPythonEnabled
            )
            recordToolToggle("python", enabled: toolPythonEnabled)
        }
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStoring
    private let keychainSaveDelay: Duration
    private var keychainSaveTask: Task<Void, Never>?
    /// 审计记录器（ADR-0009 A 域：配置与身份）。
    private let audit: AuditLogging

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore.shared,
        keychainSaveDelay: Duration = .milliseconds(600),
        audit: AuditLogging = NullAuditLogger()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.keychainSaveDelay = keychainSaveDelay
        self.audit = audit
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
        customProviderEnabled =
            defaults.bool(forKey: AppConfiguration.SettingsKey.customProviderEnabled)
        customBaseURL = defaults.string(forKey: AppConfiguration.SettingsKey.customBaseURL) ?? ""
        if let data = defaults.data(forKey: AppConfiguration.SettingsKey.customModels),
            let models = try? JSONDecoder().decode([CustomModel].self, from: data)
        {
            customModels = models
        } else {
            customModels = []
        }
        windowSizePreset =
            WindowSizePreset(
                rawValue: defaults.string(forKey: AppConfiguration.SettingsKey.windowSizePreset)
                    ?? ""
            )
            ?? .large
        if let data = defaults.data(forKey: AppConfiguration.SettingsKey.corpora),
            let decoded = try? JSONDecoder().decode([LibraryCorpus].self, from: data)
        {
            corpora = decoded
        } else {
            corpora = []
        }
        deliberationDuration =
            DeliberationDuration(
                rawValue:
                    defaults.string(forKey: AppConfiguration.SettingsKey.deliberationDuration) ?? ""
            )
            ?? .minutes5
        toolCalculatorEnabled =
            defaults.object(forKey: AppConfiguration.SettingsKey.toolCalculatorEnabled) as? Bool
            ?? true
        toolReadFileEnabled =
            defaults.object(forKey: AppConfiguration.SettingsKey.toolReadFileEnabled) as? Bool
            ?? false
        toolPythonEnabled =
            defaults.object(forKey: AppConfiguration.SettingsKey.toolPythonEnabled) as? Bool
            ?? false
        // 历史数据可能选中了已不存在的自定义模型，初始化后兜底一次。
        if !availableModels.contains(where: { $0.id == model }) {
            model = "deepseek-v4-flash"
        }
    }

    var keyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前生效的 API 地址：启用自定义供应商且填写了地址时用自定义地址，
    /// 否则回退 DeepSeek 官方地址。
    var activeBaseURL: String {
        guard customProviderEnabled else { return AppConfiguration.defaultAPIBaseURL }
        let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConfiguration.defaultAPIBaseURL : trimmed
    }

    /// 可选模型列表：启用自定义供应商时合并自定义模型。
    var availableModels: [ModelInfo] {
        ModelCatalog.all(custom: customProviderEnabled ? customModels : [])
    }

    /// 按 ID 解析模型信息（含自定义模型）。
    func modelInfo(for id: String) -> ModelInfo {
        ModelCatalog.info(id, custom: customProviderEnabled ? customModels : [])
    }

    /// 用户是否在设置页明确选择过窗口大小档位。
    ///
    /// 只有显式选择后，「每次启动按档位生效」才覆盖 autosave 记忆的旧 frame；
    /// 从未设置过的用户保持 0.2.x 的窗口记忆行为，避免无声改变既有窗口。
    var hasChosenWindowSize: Bool {
        defaults.object(forKey: AppConfiguration.SettingsKey.windowSizePreset) != nil
    }

    private func persistKey(value: String) {
        if value.isEmpty {
            keychain.delete(account: AppConfiguration.keychainAPIKeyAccount)
            audit.record(
                domain: .config,
                category: AuditCategory.apiKeyDeleted,
                message: "API Key 已从钥匙串删除"
            )
        } else {
            keychain.write(account: AppConfiguration.keychainAPIKeyAccount, value: value)
            audit.record(
                domain: .config,
                category: AuditCategory.apiKeyWritten,
                message: "API Key 已写入钥匙串"
            )
        }
    }

    private func recordToolToggle(_ tool: String, enabled: Bool) {
        audit.record(
            domain: .config,
            category: AuditCategory.toolToggleChanged,
            message: "工具开关变更",
            metadata: ["tool": tool, "enabled": String(enabled)]
        )
    }

    /// 资料库增删 / 启用变更审计（A 域 + permission.corpusAuthorized）。
    private func auditCorpusChanges(from old: [LibraryCorpus], to new: [LibraryCorpus]) {
        for corpus in new where !old.contains(where: { $0.id == corpus.id }) {
            audit.record(
                domain: .config,
                category: AuditCategory.corpusAdded,
                message: "资料库已添加：\(corpus.name)",
                metadata: ["path": AuditRedactor.summary(for: corpus.path)]
            )
            if corpus.bookmarkData != nil {
                audit.record(
                    domain: .permission,
                    category: AuditCategory.corpusAuthorized,
                    message: "资料库目录授权已建立",
                    metadata: ["path": AuditRedactor.summary(for: corpus.path)]
                )
            }
        }
        for corpus in old where !new.contains(where: { $0.id == corpus.id }) {
            audit.record(
                domain: .config,
                category: AuditCategory.corpusRemoved,
                message: "资料库已移除：\(corpus.name)",
                metadata: ["path": AuditRedactor.summary(for: corpus.path)]
            )
        }
        for oldCorpus in old {
            guard let newCorpus = new.first(where: { $0.id == oldCorpus.id }),
                oldCorpus.isEnabled != newCorpus.isEnabled
            else { continue }
            audit.record(
                domain: .config,
                category: AuditCategory.corpusToggled,
                message: "资料库开关变更：\(newCorpus.name)",
                metadata: ["enabled": String(newCorpus.isEnabled)]
            )
        }
    }
}
