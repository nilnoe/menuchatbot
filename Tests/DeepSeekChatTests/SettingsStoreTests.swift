import XCTest

@testable import DeepSeekChat

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var mockKeychain: MockKeychain!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        mockKeychain = MockKeychain()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(
        keychain: KeychainStoring? = nil,
        saveDelay: Duration = .zero
    ) -> SettingsStore {
        SettingsStore(
            defaults: defaults,
            keychain: keychain ?? mockKeychain,
            keychainSaveDelay: saveDelay
        )
    }

    // MARK: - 设置持久化

    func testSettingsRoundTrip() {
        let store = makeStore()
        store.model = "deepseek-v4-pro"
        store.thinking = false
        store.effort = .max
        store.webSearch = true
        store.systemPrompt = "你是一位资深 Swift 工程师"
        store.temperature = 0.7

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.model, "deepseek-v4-pro")
        XCTAssertFalse(reloaded.thinking)
        XCTAssertEqual(reloaded.effort, .max)
        XCTAssertTrue(reloaded.webSearch)
        XCTAssertEqual(reloaded.systemPrompt, "你是一位资深 Swift 工程师")
        XCTAssertEqual(reloaded.temperature, 0.7)
    }

    func testCustomProviderSettingsRoundTrip() {
        let store = makeStore()
        store.customProviderEnabled = true
        store.customBaseURL = "https://api.example.com/v1"
        store.customModels = [
            CustomModel(id: "gpt-4o", name: "GPT-4o"),
            CustomModel(id: "claude-sonnet", name: "Claude Sonnet"),
        ]

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.customProviderEnabled)
        XCTAssertEqual(reloaded.customBaseURL, "https://api.example.com/v1")
        XCTAssertEqual(
            reloaded.customModels,
            [
                CustomModel(id: "gpt-4o", name: "GPT-4o"),
                CustomModel(id: "claude-sonnet", name: "Claude Sonnet"),
            ]
        )
    }

    func testWindowSizePresetRoundTrip() {
        let store = makeStore()
        XCTAssertEqual(store.windowSizePreset, .large, "默认档位与 0.2.x 的 93% 铺满一致")
        XCTAssertFalse(store.hasChosenWindowSize, "未设置过时保持旧窗口记忆行为")

        store.windowSizePreset = .compact
        XCTAssertTrue(store.hasChosenWindowSize)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.windowSizePreset, .compact)
        XCTAssertTrue(reloaded.hasChosenWindowSize)
    }

    func testInvalidWindowSizePresetFallsBackToLarge() {
        defaults.set("bogus", forKey: "windowSizePreset")
        XCTAssertEqual(makeStore().windowSizePreset, .large)
    }

    func testCustomProviderDefaultsWhenNothingSaved() {
        let store = makeStore()
        XCTAssertFalse(store.customProviderEnabled)
        XCTAssertEqual(store.customBaseURL, "")
        XCTAssertTrue(store.customModels.isEmpty)
    }

    func testActiveBaseURLFallsBackToOfficial() {
        let store = makeStore()
        XCTAssertEqual(store.activeBaseURL, AppConfiguration.defaultAPIBaseURL)

        // 启用但地址为空：仍回退官方地址
        store.customProviderEnabled = true
        XCTAssertEqual(store.activeBaseURL, AppConfiguration.defaultAPIBaseURL)

        // 自定义地址生效（含首尾空白裁剪）
        store.customBaseURL = "  https://api.example.com/v1  "
        XCTAssertEqual(store.activeBaseURL, "https://api.example.com/v1")

        // 关闭供应商后恢复官方地址
        store.customProviderEnabled = false
        XCTAssertEqual(store.activeBaseURL, AppConfiguration.defaultAPIBaseURL)
    }

    func testAvailableModelsMergeCustomWhenEnabled() {
        let store = makeStore()
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]

        // 未启用：只暴露内置模型
        XCTAssertEqual(store.availableModels.map(\.id), ["deepseek-v4-flash", "deepseek-v4-pro"])

        // 启用：合并自定义模型
        store.customProviderEnabled = true
        XCTAssertEqual(
            store.availableModels.map(\.id),
            ["deepseek-v4-flash", "deepseek-v4-pro", "gpt-4o"]
        )
        XCTAssertTrue(store.modelInfo(for: "gpt-4o").isCustom)
        XCTAssertFalse(store.modelInfo(for: "gpt-4o").supportsResponses)
    }

    func testDisablingProviderResetsCustomModelSelection() {
        let store = makeStore()
        store.customProviderEnabled = true
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        store.model = "gpt-4o"

        store.customProviderEnabled = false
        XCTAssertEqual(store.model, "deepseek-v4-flash", "关闭供应商后选中项应回退内置模型")
    }

    func testDeletingSelectedCustomModelResetsSelection() {
        let store = makeStore()
        store.customProviderEnabled = true
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        store.model = "gpt-4o"

        store.customModels = []
        XCTAssertEqual(store.model, "deepseek-v4-flash", "删除选中的自定义模型后应回退内置模型")
    }

    func testReloadKeepsBuiltinSelectionWhenProviderOff() {
        let store = makeStore()
        store.model = "deepseek-v4-pro"
        store.customProviderEnabled = true
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        store.model = "gpt-4o"
        store.customProviderEnabled = false

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.model, "deepseek-v4-flash", "关闭后持久化的自定义选择不应复活")
    }

    func testDefaultsWhenNothingSaved() {
        let store = makeStore()
        XCTAssertEqual(store.model, "deepseek-v4-flash")
        XCTAssertTrue(store.thinking)
        XCTAssertEqual(store.effort, .high)
        XCTAssertFalse(store.webSearch)
        XCTAssertEqual(store.systemPrompt, "")
        XCTAssertNil(store.temperature)
        XCTAssertEqual(store.windowSizePreset, .large)
        XCTAssertEqual(store.apiKey, "")
        XCTAssertFalse(store.keyConfigured)
    }

    func testClearingTemperatureReturnsToModelDefault() {
        let store = makeStore()
        store.temperature = 1.5
        XCTAssertEqual(store.temperature, 1.5)
        store.temperature = nil
        XCTAssertNil(store.temperature)

        let reloaded = makeStore()
        XCTAssertNil(reloaded.temperature)
    }

    func testLegacyModelNamesMigrated() {
        defaults.set("deepseek-chat", forKey: "model")
        XCTAssertEqual(makeStore().model, "deepseek-v4-flash")

        defaults.set("deepseek-reasoner", forKey: "model")
        XCTAssertEqual(makeStore().model, "deepseek-v4-flash")
    }

    func testInvalidEffortFallsBackToHigh() {
        defaults.set("bogus", forKey: "effort")
        XCTAssertEqual(makeStore().effort, .high)
    }

    // MARK: - API Key

    func testAPIKeyWritesToKeychainSynchronously() {
        let store = makeStore(saveDelay: .zero)
        store.apiKey = "sk-test-123"
        XCTAssertEqual(mockKeychain.storage["apiKey"], "sk-test-123")
        XCTAssertEqual(mockKeychain.writeCount, 1)
        XCTAssertTrue(store.keyConfigured)
    }

    func testEmptyAPIKeyDeletesFromKeychain() {
        mockKeychain.storage["apiKey"] = "sk-old"
        let store = makeStore(saveDelay: .zero)
        XCTAssertEqual(store.apiKey, "sk-old")
        store.apiKey = ""
        XCTAssertNil(mockKeychain.storage["apiKey"])
        XCTAssertEqual(mockKeychain.deleteCount, 1)
        XCTAssertFalse(store.keyConfigured)
    }

    func testKeychainValueLoadedAtInit() {
        mockKeychain.storage["apiKey"] = "sk-from-keychain"
        let store = makeStore()
        XCTAssertEqual(store.apiKey, "sk-from-keychain")
        XCTAssertTrue(store.keyConfigured)
    }

    func testWhitespaceOnlyKeyNotConfigured() {
        let store = makeStore(saveDelay: .zero)
        store.apiKey = "   "
        XCTAssertFalse(store.keyConfigured)
    }

    func testDefaultDelayDefersKeychainWrite() {
        let store = makeStore(saveDelay: .milliseconds(600))
        store.apiKey = "sk-deferred"
        // 防抖生效：写入尚未发生
        XCTAssertNil(mockKeychain.storage["apiKey"])
        XCTAssertEqual(mockKeychain.writeCount, 0)
    }

    func testRapidKeyChangesOnlyPersistLastValue() async throws {
        let store = makeStore(saveDelay: .milliseconds(200))
        store.apiKey = "sk-1"
        store.apiKey = "sk-2"
        store.apiKey = "sk-3"

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(mockKeychain.storage["apiKey"], "sk-3")
        XCTAssertEqual(mockKeychain.writeCount, 1)
    }
}
