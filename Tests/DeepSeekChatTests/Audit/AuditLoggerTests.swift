import Foundation
import XCTest

@testable import DeepSeekChat

/// AU-3 / AU-4：入队非阻塞、批量有序、sink 故障不阻塞业务。
final class AuditLoggerTests: XCTestCase {
    func testRecordBatchesInOrderAndFlushSyncAU3() {
        let recorder = AuditRecorderSink()
        let logger = makeAuditLogger(sinks: [recorder], batchSize: 1000)
        for index in 0..<100 {
            logger.record(
                AuditEvent(
                    domain: .config,
                    category: "config.order.\(index)",
                    message: "事件 \(index)"
                )
            )
        }
        XCTAssertEqual(logger.pendingCount(), 100, "未达批次阈值前只入队")
        logger.flushSync()
        XCTAssertEqual(recorder.count, 100)
        XCTAssertEqual(
            recorder.events.map(\.category),
            (0..<100).map { "config.order.\($0)" },
            "AU-3：事件按入队顺序送达"
        )
    }

    func testRecordEnqueueLatencyBoundAU3() {
        let recorder = AuditRecorderSink()
        let logger = makeAuditLogger(sinks: [recorder], batchSize: 1000)
        let event = AuditEvent(domain: .config, category: "config.x", message: "x")
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<2000 {
            logger.record(event)
        }
        let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(
            elapsed, .seconds(1),
            "AU-3：2000 次入队 < 1s（均值 < 0.5ms；正式阈值按 ACCEPTANCE §9 校准）"
        )
    }

    func testOneFailingSinkDoesNotBlockOthersAU4() {
        // 「失败」sink：静默丢弃（模拟审计库写入故障）。
        final class DroppingSink: AuditSink {
            func record(_ event: AuditEvent) {}
        }
        let recorder = AuditRecorderSink()
        let logger = makeAuditLogger(sinks: [DroppingSink(), recorder])
        logger.record(
            AuditEvent(domain: .permission, category: AuditCategory.pathDenied, message: "拒绝")
        )
        logger.flushSync()
        XCTAssertEqual(recorder.count, 1, "AU-4：单个 sink 故障不影响其他 sink")
    }

    func testBusinessUnaffectedWhenAuditSinkFailsAU4() {
        final class DroppingSink: AuditSink {
            func record(_ event: AuditEvent) {}
        }
        let logger = makeAuditLogger(sinks: [DroppingSink()])
        let defaults = UserDefaults(suiteName: "AuditLogger-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: "AuditLogger") }
        let settings = SettingsStore(
            defaults: defaults,
            keychain: MockKeychain(),
            keychainSaveDelay: .zero,
            audit: logger
        )
        settings.toolPythonEnabled = true
        XCTAssertTrue(settings.toolPythonEnabled, "AU-4：审计故障不影响业务状态")
    }
}
