import XCTest

@testable import DeepSeekChat

/// AI 能力设置：命名资料库、长时推演时长、工具开关的默认值与持久化
/// （Tier 1 第二批）。
final class SettingsStoreAIFeatureTests: XCTestCase {
    private var harness: SettingsStoreHarness!

    override func setUpWithError() throws {
        harness = SettingsStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    func testCorporaDefaultsEmptyAndRoundTrips() {
        let store = harness.makeStore()
        XCTAssertTrue(store.corpora.isEmpty)

        store.corpora = [
            LibraryCorpus(
                id: UUID(),
                name: "工作文档",
                path: "/tmp/work",
                isEnabled: true,
                bookmarkData: nil
            )
        ]
        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.corpora, store.corpora)
    }

    func testDeliberationDurationDefaultAndPersistence() {
        let store = harness.makeStore()
        XCTAssertEqual(store.deliberationDuration, .minutes5)

        store.deliberationDuration = .minutes20
        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.deliberationDuration, .minutes20)
        XCTAssertEqual(DeliberationDuration.minutes20.minutes, 20)
        XCTAssertEqual(DeliberationDuration.minutes20.label, "20 分钟")
    }

    func testToolSwitchesDefaultsAndPersistence() {
        let store = harness.makeStore()
        XCTAssertTrue(store.toolCalculatorEnabled, "计算器默认开启")
        XCTAssertFalse(store.toolReadFileEnabled, "只读文件默认关闭（待授权就绪）")
        XCTAssertFalse(store.toolPythonEnabled, "python 沙箱默认关闭")

        store.toolCalculatorEnabled = false
        store.toolReadFileEnabled = true
        store.toolPythonEnabled = true

        let reloaded = harness.makeStore()
        XCTAssertFalse(reloaded.toolCalculatorEnabled)
        XCTAssertTrue(reloaded.toolReadFileEnabled)
        XCTAssertTrue(reloaded.toolPythonEnabled)
    }
}
