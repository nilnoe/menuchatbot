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
        XCTAssertEqual(center.recentEvents.count, 2, "AU-4：内存库降级后记录仍可用")

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
