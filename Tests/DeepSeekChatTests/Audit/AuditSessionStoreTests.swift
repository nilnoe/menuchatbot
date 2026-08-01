import Foundation
import XCTest

@testable import DeepSeekChat

/// D 域（storage）+ AU-10：迁移 / 导出导入 / 会话删除的审计与隔离。
final class AuditSessionStoreTests: XCTestCase {
    private var tempDir: URL!
    private var auditDir: URL!
    private var recorder: AuditRecorderSink!
    private var auditStore: AuditStore!
    private var logger: AuditLogger!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditSession-\(UUID().uuidString)")
        auditDir = tempDir.appendingPathComponent("audit")
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        recorder = AuditRecorderSink()
        auditStore = try AuditStore(directory: auditDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> SessionStore {
        logger = makeAuditLogger(sinks: [recorder, DatabaseAuditSink(store: auditStore)])
        return SessionStore(
            storageDirectory: tempDir,
            audit: logger
        )
    }

    func testFreshStoreRecordsMigrationAppliedAUDomain() {
        _ = makeStore()
        logger.flushSync()
        XCTAssertEqual(
            recorder.events(category: AuditCategory.migrationApplied).count, 1,
            "D 域：新库迁移应记录"
        )
    }

    func testExportRecordsFinishedEventAUDomain() throws {
        let store = makeStore()
        _ = store.createSession(title: "导出测试")
        logger.flushSync()
        let data = try store.exportJSON()
        XCTAssertGreaterThan(data.count, 0)
        logger.flushSync()
        XCTAssertEqual(
            recorder.events(category: AuditCategory.exportFinished).count, 1,
            "D 域：导出完成应记录"
        )
    }

    func testImportRecordsStartedAndFinishedAUDomain() throws {
        let store = makeStore()
        let backup = try store.exportJSON()
        logger.flushSync()
        _ = try store.importJSON(backup)
        logger.flushSync()
        XCTAssertEqual(recorder.events(category: AuditCategory.importStarted).count, 1)
        XCTAssertEqual(recorder.events(category: AuditCategory.importFinished).count, 1)
    }

    func testImportFailureRecordsWarningAUDomain() throws {
        let store = makeStore()
        XCTAssertThrowsError(
            try store.importJSON(Data("not json".utf8))
        )
        logger.flushSync()
        let failed = recorder.events(category: AuditCategory.importFinished)
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.severity, .warning)
    }

    func testSessionDeletionKeepsAuditRecordAU10() {
        let store = makeStore()
        let session = store.createSession(title: "待删除")
        store.deleteSession(id: session.id)
        logger.flushSync()
        XCTAssertNil(store.session(id: session.id), "AU-10：会话已删除")
        let deleted = recorder.events(category: AuditCategory.sessionDeleted)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.sessionID, session.id)
        // 审计记录独立保留（audit.sqlite 独立于 sessions.sqlite）。
        XCTAssertGreaterThan(auditStore.count(), 0, "AU-10：审计记录随会话删除保留")
    }
}
