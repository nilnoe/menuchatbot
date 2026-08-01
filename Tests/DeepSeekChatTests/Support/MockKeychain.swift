import Foundation

@testable import DeepSeekChat

/// 内存版 Keychain，用于 `SettingsStore` 测试。
///
/// 记录读写 / 删除次数，便于断言「同步写入」「防抖后仅写一次」等行为。
final class MockKeychain: KeychainStoring {
    var storage: [String: String] = [:]
    var writeCount = 0
    var deleteCount = 0

    func read(account: String) -> String? {
        storage[account]
    }

    func write(account: String, value: String) {
        storage[account] = value
        writeCount += 1
    }

    func delete(account: String) {
        storage.removeValue(forKey: account)
        deleteCount += 1
    }
}
