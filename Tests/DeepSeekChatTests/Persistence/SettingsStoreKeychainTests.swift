import XCTest

@testable import DeepSeekChat

/// API Key 与钥匙串：同步写入、删除、加载、防抖。
final class SettingsStoreKeychainTests: XCTestCase {
    private var harness: SettingsStoreHarness!

    override func setUpWithError() throws {
        harness = SettingsStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    // MARK: - API Key

    func testAPIKeyWritesToKeychainSynchronously() {
        let store = harness.makeStore(saveDelay: .zero)
        store.apiKey = "sk-test-123"
        XCTAssertEqual(harness.mockKeychain.storage["apiKey"], "sk-test-123")
        XCTAssertEqual(harness.mockKeychain.writeCount, 1)
        XCTAssertTrue(store.keyConfigured)
    }

    func testEmptyAPIKeyDeletesFromKeychain() {
        harness.mockKeychain.storage["apiKey"] = "sk-old"
        let store = harness.makeStore(saveDelay: .zero)
        XCTAssertEqual(store.apiKey, "sk-old")
        store.apiKey = ""
        XCTAssertNil(harness.mockKeychain.storage["apiKey"])
        XCTAssertEqual(harness.mockKeychain.deleteCount, 1)
        XCTAssertFalse(store.keyConfigured)
    }

    func testKeychainValueLoadedAtInit() {
        harness.mockKeychain.storage["apiKey"] = "sk-from-keychain"
        let store = harness.makeStore()
        XCTAssertEqual(store.apiKey, "sk-from-keychain")
        XCTAssertTrue(store.keyConfigured)
    }

    func testWhitespaceOnlyKeyNotConfigured() {
        let store = harness.makeStore(saveDelay: .zero)
        store.apiKey = "   "
        XCTAssertFalse(store.keyConfigured)
    }

    func testDefaultDelayDefersKeychainWrite() {
        let store = harness.makeStore(saveDelay: .milliseconds(600))
        store.apiKey = "sk-deferred"
        // 防抖生效：写入尚未发生
        XCTAssertNil(harness.mockKeychain.storage["apiKey"])
        XCTAssertEqual(harness.mockKeychain.writeCount, 0)
    }

    func testRapidKeyChangesOnlyPersistLastValue() async throws {
        let store = harness.makeStore(saveDelay: .milliseconds(200))
        store.apiKey = "sk-1"
        store.apiKey = "sk-2"
        store.apiKey = "sk-3"

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.mockKeychain.storage["apiKey"], "sk-3")
        XCTAssertEqual(harness.mockKeychain.writeCount, 1)
    }
}
