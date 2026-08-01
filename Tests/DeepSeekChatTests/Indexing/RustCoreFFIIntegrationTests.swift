import CRustCore
import XCTest

@testable import DeepSeekChatIndexing

/// Rust Core FFI 集成测试（T2-1c / T2-2a）。
///
/// 仅当 scripts/build-rust-core.sh 产出了真实 Rust 库（无 .stub 标记）时
/// 运行；stub 降级环境下 XCTSkip（T2-1d）。产物缺失 / 为 stub 都不应
/// 让 `swift test` 失败。
final class RustCoreFFIIntegrationTests: XCTestCase {
    /// 仓库根目录（相对本文件：Tests/DeepSeekChatTests/Indexing → 上三级）。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var rustCoreAvailable: Bool {
        let library = repoRoot.appendingPathComponent("RustCore/dist/librustcore.a")
        let stubMarker = repoRoot.appendingPathComponent("RustCore/dist/.stub")
        return FileManager.default.fileExists(atPath: library.path)
            && !FileManager.default.fileExists(atPath: stubMarker.path)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            rustCoreAvailable,
            "Rust 核心库不存在或为 stub（先运行 scripts/build-rust-core.sh）"
        )
    }

    // MARK: - T0 计算器（T2-2a）

    func testCalculatorRoundtrip() async throws {
        let calculator = RustCalculatorService()
        let results = [
            try await calculator.evaluate("1 + 2 * 3"),
            try await calculator.evaluate("(1+2)*3"),
            try await calculator.evaluate("2^10"),
            try await calculator.evaluate("8/4"),
            try await calculator.evaluate("7%3"),
        ]
        XCTAssertEqual(results, ["7", "9", "1024", "2", "1"])
    }

    func testCalculatorInvalidExpressionThrows() async {
        let calculator = RustCalculatorService()
        do {
            _ = try await calculator.evaluate("1/0")
            XCTFail("除零应抛出错误")
        } catch let error as CalculatorError {
            XCTAssertEqual(error, .evaluationFailed("不能除以零"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 索引 FFI 往返（T2-1c）

    func testIndexUpsertSearchDeleteRoundtrip() async throws {
        let service = RustIndexService()
        let state = await service.state
        XCTAssertEqual(state, .ready)
        let firstID = "00000000-0000-0000-0000-000000000001"
        let secondID = "00000000-0000-0000-0000-000000000002"

        let doc = IndexableMessage(
            id: firstID,
            sessionID: "s1",
            position: 0,
            contentHash: "hash-1",
            content: "香蕉牛奶",
            namespace: "history"
        )
        try await service.upsert(doc)
        try await service.upsert(
            IndexableMessage(
                id: secondID,
                sessionID: "s1",
                position: 1,
                contentHash: "hash-2",
                content: "苹果派",
                namespace: "history"
            )
        )

        let hits = try await service.search("香蕉", scope: .history, limit: 10)
        XCTAssertEqual(hits.map(\.id), [firstID])
        XCTAssertEqual(hits.first?.score, 1)

        try await service.delete(
            messageID: UUID(uuidString: firstID)!,
            sessionID: UUID()
        )
        let afterDelete = try await service.search("香蕉", scope: .history, limit: 10)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testIndexDeleteMissingThrowsNotFound() async throws {
        let service = RustIndexService()
        do {
            try await service.delete(messageID: UUID(), sessionID: UUID())
            XCTFail("删除不存在文档应抛出 notFound")
        } catch let error as IndexError {
            guard case .notFound = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 降级（T2-1d）

    func testOpenFailureMarksUnavailable() async {
        // schema 版本不匹配 → dc_index_open 返回 NULL → 降级不可用（T2-1d）。
        let service = RustIndexService(config: RustIndexConfig(schemaVersion: 999))
        let state = await service.state
        XCTAssertEqual(state, .unavailable("Rust 索引打开失败（配置非法或 Rust 核心不可用）"))
    }

    // MARK: - 审计快照（ADR-0009 P2，AU-13 / AU-14 / AU-15）

    func testAuditSnapshotCountsErrorsAU13() async throws {
        RustAudit.install(logPath: nil)
        let before = try XCTUnwrap(RustAudit.snapshot(), "Rust 库应能返回快照")

        let calculator = RustCalculatorService()
        _ = try? await calculator.evaluate("1/0")
        _ = try? await calculator.evaluate("不支持的表达式@@")

        let after = try XCTUnwrap(RustAudit.snapshot())
        let delta =
            (after.errorCounts[-1] ?? 0) - (before.errorCounts[-1] ?? 0)
        XCTAssertGreaterThanOrEqual(
            delta, 1,
            "AU-13：错误码 -1 计数应随实际返回增长"
        )
        XCTAssertGreaterThan(
            after.totalCalls, before.totalCalls,
            "AU-13：调用计数应增长"
        )
    }

    func testAuditSnapshotOutstandingAllocationsReturnToZeroAU14() async throws {
        RustAudit.install(logPath: nil)
        let calculator = RustCalculatorService()
        for index in 0..<10 {
            let output = try await calculator.evaluate("1 + \(index)")
            XCTAssertEqual(output, String(index + 1))
        }
        let snapshot = try XCTUnwrap(RustAudit.snapshot())
        XCTAssertEqual(
            snapshot.outstandingAllocations, 0,
            "AU-14：操作序列结束后未释放分配应为 0"
        )
    }
}
