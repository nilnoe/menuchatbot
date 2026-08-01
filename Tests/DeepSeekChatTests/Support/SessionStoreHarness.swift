import Foundation

@testable import DeepSeekChat

/// SessionStore 测试脚手架：每个用例一个独立临时目录。
///
/// 用法：
/// ```swift
/// final class SessionStoreFooTests: XCTestCase {
///     private var harness: SessionStoreHarness!
///
///     override func setUpWithError() throws {
///         harness = try SessionStoreHarness()
///     }
///
///     override func tearDownWithError() throws {
///         harness.cleanup()
///     }
/// }
/// ```
final class SessionStoreHarness {
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// 新建一个指向同一临时目录的 store（等价于「跨实例重载」）。
    func makeStore() -> SessionStore {
        SessionStore(storageDirectory: tempDir)
    }

    /// 向临时目录写入文件（用于构造旧版 state.json / sessions.json 等）。
    func writeFile(_ name: String, _ data: Data) throws {
        try data.write(to: tempDir.appendingPathComponent(name))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
