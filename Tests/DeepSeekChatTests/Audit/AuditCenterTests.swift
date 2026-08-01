import DeepSeekChatIndexing
import Foundation
import XCTest

@testable import DeepSeekChat

/// AU-4 / AU-7 / AU-20：组合根降级、启动保留、导出。
final class AuditCenterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditCenter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAuditCenterFallsBackToMemoryWhenStoreUnavailableAU4() async throws {
        // audit.sqlite 位置放一个目录 → DatabaseQueue 打开失败 → 降级内存库。
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("audit.sqlite"),
            withIntermediateDirectories: true
        )
        let center = AuditCenter(directory: tempDir)
        center.logger.record(
            domain: .permission,
            category: AuditCategory.pathDenied,
            message: "拒绝路径"
        )
        center.logger.record(
            domain: .config,
            category: AuditCategory.modelChanged,
            message: "切换模型"
        )
        await waitUntil(timeout: .seconds(3)) { !center.recentEvents.isEmpty }
        XCTAssertGreaterThanOrEqual(
            center.recentEvents.count, 2,
            "AU-4：内存库降级后记录仍可用"
        )
        XCTAssertTrue(
            center.recentEvents.contains { $0.category == AuditCategory.pathDenied },
            "AU-4：手动记录的事件应出现在环形缓冲"
        )
        XCTAssertTrue(
            center.recentEvents.contains { $0.category == AuditCategory.modelChanged },
            "AU-4：手动记录的事件应出现在环形缓冲"
        )

        // 业务不受影响：会话 store 照常工作。
        let store = SessionStore(storageDirectory: tempDir, audit: center.logger)
        let session = store.createSession(title: "业务不受影响")
        XCTAssertEqual(store.session(id: session.id)?.title, "业务不受影响")
    }

    func testStartupRetentionRunsWithPolicyAU7() throws {
        let center = AuditCenter(directory: tempDir)
        let old = AuditEvent(
            timestamp: Date().addingTimeInterval(-200 * 86_400),
            domain: .config,
            category: "config.old",
            message: "旧事件"
        )
        center.store.insert(old)
        let removed = center.store.prune(
            before: Date().addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(removed, 1, "AU-7：策略修剪生效")
    }

    func testExportRoundtripAU20() throws {
        let center = AuditCenter(directory: tempDir)
        center.store.insert(
            AuditEvent(domain: .tool, category: AuditCategory.executionSuccess, message: "ok")
        )
        let data = try center.exportJSON()
        let decoded = try JSONDecoder().decode([AuditEvent].self, from: data)
        XCTAssertEqual(decoded.count, center.store.count(), "AU-20：导出与库内一致")
        XCTAssertEqual(decoded.first?.category, AuditCategory.executionSuccess)
    }

    func testRustAuditCollectionRecordsFFIEventsAU13() async throws {
        guard RustAudit.snapshot() != nil else {
            throw XCTSkip("Rust 库不可用（stub 降级），FFI 事件测试跳过")
        }
        let center = AuditCenter(directory: tempDir)
        center.flushAuditLog()
        let beforeCount = center.store.recent(limit: 100, domain: .ffi).count

        let calculator = RustCalculatorService()
        _ = try? await calculator.evaluate("1/0")
        center.collectRustAudit()
        center.flushAuditLog()

        let ffiEvents = center.store.recent(limit: 100, domain: .ffi)
        XCTAssertGreaterThan(
            ffiEvents.count, beforeCount,
            "AU-13：Rust 调用后应产生 ffi 事件"
        )
        XCTAssertTrue(
            ffiEvents.contains { $0.category == AuditCategory.ffiError },
            "AU-13：错误码增量应产生 ffi.error 事件"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("等待条件超时")
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
