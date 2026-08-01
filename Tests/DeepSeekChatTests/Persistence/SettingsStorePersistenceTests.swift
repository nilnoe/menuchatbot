import XCTest

@testable import DeepSeekChat

/// 设置持久化：往返、默认值、自定义供应商、兼容旧键名。
final class SettingsStorePersistenceTests: XCTestCase {
    private var harness: SettingsStoreHarness!

    override func setUpWithError() throws {
        harness = SettingsStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    // MARK: - 设置持久化

    func testSettingsRoundTrip() {
        let store = harness.makeStore()
        store.model = "deepseek-v4-pro"
        store.thinking = false
        store.effort = .max
        store.webSearch = true
        store.systemPrompt = "你是一位资深 Swift 工程师"
        store.temperature = 0.7

        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.model, "deepseek-v4-pro")
        XCTAssertFalse(reloaded.thinking)
        XCTAssertEqual(reloaded.effort, .max)
        XCTAssertTrue(reloaded.webSearch)
        XCTAssertEqual(reloaded.systemPrompt, "你是一位资深 Swift 工程师")
        XCTAssertEqual(reloaded.temperature, 0.7)
    }

    func testCustomProviderSettingsRoundTrip() {
        let store = harness.makeStore()
        store.customProviderEnabled = true
        store.customBaseURL = "https://api.example.com/v1"
        store.customModels = [
            CustomModel(id: "gpt-4o", name: "GPT-4o"),
            CustomModel(id: "claude-sonnet", name: "Claude Sonnet"),
        ]

        let reloaded = harness.makeStore()
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
        let store = harness.makeStore()
        XCTAssertEqual(store.windowSizePreset, .large, "默认档位与 0.2.x 的 93% 铺满一致")
        XCTAssertFalse(store.hasChosenWindowSize, "未设置过时保持旧窗口记忆行为")

        store.windowSizePreset = .compact
        XCTAssertTrue(store.hasChosenWindowSize)

        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.windowSizePreset, .compact)
        XCTAssertTrue(reloaded.hasChosenWindowSize)
    }

    func testInvalidWindowSizePresetFallsBackToLarge() {
        harness.defaults.set("bogus", forKey: "windowSizePreset")
        XCTAssertEqual(harness.makeStore().windowSizePreset, .large)
    }

    func testCustomProviderDefaultsWhenNothingSaved() {
        let store = harness.makeStore()
        XCTAssertFalse(store.customProviderEnabled)
        XCTAssertEqual(store.customBaseURL, "")
        XCTAssertTrue(store.customModels.isEmpty)
    }

    func testActiveBaseURLFallsBackToOfficial() {
        let store = harness.makeStore()
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
        let store = harness.makeStore()
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
        let store = harness.makeStore()
        store.customProviderEnabled = true
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        store.model = "gpt-4o"

        store.customProviderEnabled = false
        XCTAssertEqual(store.model, "deepseek-v4-flash", "关闭供应商后选中项应回退内置模型")
    }

    func testDeletingSelectedCustomModelResetsSelection() {
        let store = harness.makeStore()
        store.customProviderEnabled = true
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        store.model = "gpt-4o"

        store.customModels = []
        XCTAssertEqual(store.model, "deepseek-v4-flash", "删除选中的自定义模型后应回退内置模型")
    }

    func testReloadKeepsBuiltinSelectionWhenProviderOff() {
        let store = harness.makeStore()
        store.model = "deepseek-v4-pro"
        store.customProviderEnabled = true
        store.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        store.model = "gpt-4o"
        store.customProviderEnabled = false

        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.model, "deepseek-v4-flash", "关闭后持久化的自定义选择不应复活")
    }

    func testDefaultsWhenNothingSaved() {
        let store = harness.makeStore()
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
        let store = harness.makeStore()
        store.temperature = 1.5
        XCTAssertEqual(store.temperature, 1.5)
        store.temperature = nil
        XCTAssertNil(store.temperature)

        let reloaded = harness.makeStore()
        XCTAssertNil(reloaded.temperature)
    }

    func testLegacyModelNamesMigrated() {
        harness.defaults.set("deepseek-chat", forKey: "model")
        XCTAssertEqual(harness.makeStore().model, "deepseek-v4-flash")

        harness.defaults.set("deepseek-reasoner", forKey: "model")
        XCTAssertEqual(harness.makeStore().model, "deepseek-v4-flash")
    }

    func testInvalidEffortFallsBackToHigh() {
        harness.defaults.set("bogus", forKey: "effort")
        XCTAssertEqual(harness.makeStore().effort, .high)
    }
}
