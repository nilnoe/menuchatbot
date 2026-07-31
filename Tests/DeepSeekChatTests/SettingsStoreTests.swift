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

    func testDefaultsWhenNothingSaved() {
        let store = makeStore()
        XCTAssertEqual(store.model, "deepseek-v4-flash")
        XCTAssertTrue(store.thinking)
        XCTAssertEqual(store.effort, .high)
        XCTAssertFalse(store.webSearch)
        XCTAssertEqual(store.systemPrompt, "")
        XCTAssertNil(store.temperature)
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
