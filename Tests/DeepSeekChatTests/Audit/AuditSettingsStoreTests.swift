import Foundation
import XCTest

@testable import DeepSeekChat

/// A 域（config）：设置变更产生审计事件；密钥只记生命周期不记值。
final class AuditSettingsStoreTests: XCTestCase {
    private var harness: SettingsStoreHarness!
    private var recorder: AuditRecorderSink!
    private var logger: AuditLogger!

    override func setUpWithError() throws {
        harness = SettingsStoreHarness()
        recorder = AuditRecorderSink()
        logger = makeAuditLogger(sinks: [recorder])
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    func testToolToggleRecordsEventAUConfig() {
        let store = harness.makeStore(audit: logger)
        store.toolCalculatorEnabled = false
        store.toolPythonEnabled = true
        logger.flushSync()
        let events = recorder.events(category: AuditCategory.toolToggleChanged)
        XCTAssertEqual(events.count, 2)
        let calculator = events.first { $0.metadataJSON?.contains("calculator") == true }
        let python = events.first { $0.metadataJSON?.contains("python") == true }
        XCTAssertNotNil(calculator, "A 域：计算器开关应有审计")
        XCTAssertNotNil(python)
        XCTAssertTrue(
            calculator?.metadataJSON?.contains("\"enabled\":\"false\"") == true,
            "A 域：metadata 应记录开关状态"
        )
    }

    func testCorpusAddRecordsConfigAndPermissionEventsAUConfig() {
        let store = harness.makeStore(audit: logger)
        let corpus = LibraryCorpus(
            id: UUID(),
            name: "笔记",
            path: "/Users/test/笔记",
            isEnabled: true,
            bookmarkData: Data([0x01])
        )
        store.corpora.append(corpus)
        logger.flushSync()
        XCTAssertEqual(
            recorder.events(category: AuditCategory.corpusAdded).count, 1,
            "A 域：资料库添加应有审计"
        )
        XCTAssertEqual(
            recorder.events(category: AuditCategory.corpusAuthorized).count, 1,
            "B 域：bookmark 授权应同步记录"
        )
    }

    func testCorpusRemoveAndToggleRecordEventsAUConfig() {
        let store = harness.makeStore(audit: logger)
        let corpus = LibraryCorpus(
            id: UUID(),
            name: "资料",
            path: "/tmp/资料",
            isEnabled: true,
            bookmarkData: nil
        )
        store.corpora.append(corpus)
        logger.flushSync()
        recorder.clear()

        store.corpora[0].isEnabled = false
        logger.flushSync()
        XCTAssertEqual(recorder.events(category: AuditCategory.corpusToggled).count, 1)

        store.corpora.removeAll()
        logger.flushSync()
        XCTAssertEqual(recorder.events(category: AuditCategory.corpusRemoved).count, 1)
    }

    func testAPIKeyWriteRecordsLifecycleNotValueAUConfig() {
        let key = "sk-abcdefghijklmnop12345678"
        let store = harness.makeStore(audit: logger)
        store.apiKey = key
        logger.flushSync()
        let written = recorder.events(category: AuditCategory.apiKeyWritten)
        XCTAssertEqual(written.count, 1, "A 域：API Key 写入应记录")
        let allMessages = recorder.events.map(\.message).joined()
        XCTAssertFalse(
            allMessages.contains(key),
            "AU-8：审计不得包含 API Key 本身"
        )

        store.apiKey = ""
        logger.flushSync()
        XCTAssertEqual(recorder.events(category: AuditCategory.apiKeyDeleted).count, 1)
    }

    func testModelAndDeliberationChangesRecordAUConfig() {
        let store = harness.makeStore(audit: logger)
        store.model = "deepseek-v4-pro"
        store.deliberationDuration = .minutes20
        logger.flushSync()
        XCTAssertEqual(recorder.events(category: AuditCategory.modelChanged).count, 1)
        XCTAssertEqual(
            recorder.events(category: AuditCategory.deliberationDurationChanged).count, 1
        )
        XCTAssertTrue(
            recorder.events(category: AuditCategory.modelChanged).first?.metadataJSON?
                .contains("deepseek-v4-pro") == true
        )
    }
}
