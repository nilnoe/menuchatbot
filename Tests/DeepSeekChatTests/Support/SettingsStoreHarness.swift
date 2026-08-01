import Foundation

@testable import DeepSeekChat

/// SettingsStore 测试脚手架：每个用例一个隔离的 UserDefaults 套件 + 内存 Keychain。
///
/// 用法同 `SessionStoreHarness`：setUp 创建、tearDown 调用 `cleanup()`。
final class SettingsStoreHarness {
    let defaults: UserDefaults
    let mockKeychain: MockKeychain
    private let suiteName: String

    init() {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        // 独立 suiteName 保证唯一，解包安全。
        defaults = UserDefaults(suiteName: suiteName)!
        mockKeychain = MockKeychain()
    }

    /// 新建 SettingsStore；默认零防抖、使用本脚手架的内存 Keychain。
    func makeStore(
        keychain: KeychainStoring? = nil,
        saveDelay: Duration = .zero,
        audit: AuditLogging? = nil
    ) -> SettingsStore {
        SettingsStore(
            defaults: defaults,
            keychain: keychain ?? mockKeychain,
            keychainSaveDelay: saveDelay,
            audit: audit ?? NullAuditLogger()
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
