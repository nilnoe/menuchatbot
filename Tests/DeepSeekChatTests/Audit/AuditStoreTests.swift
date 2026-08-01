import Foundation
import XCTest

@testable import DeepSeekChat

/// AU-2 / AU-5 / AU-6 / AU-7：追加式、持久化、容量上界、保留策略。
final class AuditStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() throws -> AuditStore {
        try AuditStore(directory: tempDir)
    }

    private func event(_ category: String, message: String = "事件") -> AuditEvent {
        AuditEvent(domain: .config, category: category, message: message)
    }

    func testInsertAndMonotonicIDsAU2() throws {
        let store = try makeStore()
        for index in 0..<10 {
            store.insert(event("config.test.\(index)"))
        }
        XCTAssertEqual(store.count(), 10)
        let ids = store.recent(limit: 100).compactMap(\.id)
        XCTAssertEqual(ids.count, 10)
        XCTAssertEqual(Set(ids).count, 10, "AU-2：id 必须唯一")
        // recent 按 id 倒序 → 严格递减 = 插入序单调递增。
        for index in 1..<ids.count {
            XCTAssertGreaterThan(ids[index - 1], ids[index], "AU-2：id 单调递增")
        }
    }

    func testEventsSurviveReopenWithoutLossAU5() throws {
        let store = try makeStore()
        for index in 0..<50 {
            store.insert(event("config.test.\(index)"))
        }
        // 等价「优雅退出后重启」：重新打开同一目录。
        let reopened = try AuditStore(directory: tempDir)
        XCTAssertEqual(reopened.count(), 50, "AU-5：优雅重启事件零丢失")
        XCTAssertEqual(reopened.recent(limit: 1).first?.category, "config.test.49")
    }

    func testBulkInsertIsTransactionalAU6() throws {
        let store = try makeStore()
        let events = (0..<100_000).map { event("config.test.\($0)") }
        let clock = ContinuousClock()
        let start = clock.now
        store.insert(events)
        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(store.count(), 100_000)
        XCTAssertLessThan(
            elapsed, .seconds(10),
            "AU-6：10 万事件批量入库 < 10s（实测 \(elapsed)）"
        )
    }

    func testPruneByAgeAU7() throws {
        let store = try makeStore()
        let old = AuditEvent(
            timestamp: Date().addingTimeInterval(-200 * 86_400),
            domain: .config,
            category: "config.old",
            message: "旧事件"
        )
        let recent = AuditEvent(
            timestamp: Date(),
            domain: .config,
            category: "config.recent",
            message: "新事件"
        )
        store.insert([old, recent])
        let removed = store.prune(before: Date().addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(removed, 1, "AU-7：窗口外事件 100% 修剪")
        XCTAssertEqual(store.count(), 1, "AU-7：窗口内事件 100% 存活")
        XCTAssertEqual(store.recent().first?.category, "config.recent")
    }

    func testPruneToSizeKeepsNewestAU7() throws {
        let store = try makeStore()
        let events = (0..<10).map { index in
            event(
                "config.size.\(index)",
                message: String(repeating: "x", count: 100)
            )
        }
        store.insert(events)
        // 单条约 228 字节；上限 500 → 只保留最新 2 条。
        let removed = store.pruneToApproximateSize(500)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertLessThanOrEqual(store.count(), 2, "AU-7：超容量滚动修剪最旧事件")
        XCTAssertEqual(
            store.recent(limit: 1).first?.category, "config.size.9",
            "AU-7：最新事件必须保留"
        )
    }

    func testExportRoundtripAU20() throws {
        let store = try makeStore()
        store.insert([event("config.a"), event("config.b")])
        let data = try store.exportJSON()
        let decoded = try JSONDecoder().decode([AuditEvent].self, from: data)
        XCTAssertEqual(decoded.count, 2, "AU-20：导出事件数与库内一致")
        XCTAssertEqual(
            Set(decoded.map(\.category)), Set(["config.a", "config.b"]),
            "AU-20：导出字段与库内一致"
        )
    }
}
