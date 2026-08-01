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

    // MARK: - Tier 3 资料库索引（T3-1 / T3-2c）

    /// 构造临时语料目录：返回 (目录, 内容写入闭包)。
    private func makeCorpusDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-ffi-corpus-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeIndexRoot(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-ffi-index-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCorpusIndexingRoundtripAndIncremental() async throws {
        let corpus = makeCorpusDir("roundtrip")
        defer { try? FileManager.default.removeItem(at: corpus) }
        try "苹果种植指南：施肥与浇水".write(
            to: corpus.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "香蕉牛奶制作方法".write(
            to: corpus.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let indexRoot = makeIndexRoot("roundtrip")
        defer { try? FileManager.default.removeItem(at: indexRoot) }
        let indexer = RustLibraryIndexer(indexRoot: indexRoot)
        let corpusID = UUID()

        let report = try await indexer.indexCorpus(
            corpusID: corpusID,
            name: "资料库一",
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )
        XCTAssertEqual(report.filesIndexed, 2, "首次应全量索引")
        XCTAssertGreaterThanOrEqual(report.chunksTotal, 2)

        // 检索命中带来源路径（T3-3a）。
        let hits = try await indexer.search(corpusID: corpusID, query: "香蕉", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].path.hasSuffix("b.txt"), "命中应带来源路径：\(hits[0].path)")

        // 增量：mtime + hash 未变 → 不重 embed（T3-1c）。
        let report2 = try await indexer.indexCorpus(
            corpusID: corpusID,
            name: "资料库一",
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )
        XCTAssertEqual(report2.filesIndexed, 0, "未变化文件不应重索引")
        XCTAssertEqual(report2.filesRemoved, 0)

        // 修改 + 删除 → 增量一致。
        try "苹果种植指南：新版施肥方法".write(
            to: corpus.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: corpus.appendingPathComponent("b.txt"))
        let report3 = try await indexer.indexCorpus(
            corpusID: corpusID,
            name: "资料库一",
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )
        XCTAssertEqual(report3.filesIndexed, 1)
        XCTAssertEqual(report3.filesRemoved, 1)
        let afterDelete = try await indexer.search(corpusID: corpusID, query: "香蕉", limit: 5)
        XCTAssertTrue(afterDelete.isEmpty, "删除文件后其分块应消失")

        let snapshot = await indexer.snapshot(corpusID: corpusID)
        XCTAssertEqual(snapshot.fileCount, 1)
        XCTAssertEqual(snapshot.documentCount, report3.chunksTotal)
        XCTAssertNotNil(snapshot.indexedAt)
    }

    func testCorpusIndexPersistsAcrossRestart() async throws {
        let corpus = makeCorpusDir("persist")
        defer { try? FileManager.default.removeItem(at: corpus) }
        try "苹果种植指南".write(
            to: corpus.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let indexRoot = makeIndexRoot("persist")
        defer { try? FileManager.default.removeItem(at: indexRoot) }
        let corpusID = UUID()

        let first = RustLibraryIndexer(indexRoot: indexRoot)
        _ = try await first.indexCorpus(
            corpusID: corpusID,
            name: "持久化",
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )

        // 新实例（模拟重启）：索引从磁盘恢复，无需重新索引即可检索（T3-2c）。
        let second = RustLibraryIndexer(indexRoot: indexRoot)
        let hits = try await second.search(corpusID: corpusID, query: "苹果", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].path.hasSuffix("a.md"))

        // 删除索引目录后重扫可重建（派生数据原则）。
        let indexDir = indexRoot.appendingPathComponent(corpusID.uuidString, isDirectory: true)
        try FileManager.default.removeItem(at: indexDir)
        let third = RustLibraryIndexer(indexRoot: indexRoot)
        let report = try await third.indexCorpus(
            corpusID: corpusID,
            name: "持久化",
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )
        XCTAssertEqual(report.filesIndexed, 1, "索引目录删除后应能整体重建")
    }

    func testCorpusCancelDoesNotPermanentlyDisableHandle() async throws {
        let corpus = makeCorpusDir("cancel")
        defer { try? FileManager.default.removeItem(at: corpus) }
        for index in 0..<30 {
            let content = String(repeating: "文档 \(index) 内容：苹果香蕉水果指南 ", count: 60)
            try content.write(
                to: corpus.appendingPathComponent("f\(index).md"),
                atomically: true,
                encoding: .utf8
            )
        }
        let indexRoot = makeIndexRoot("cancel")
        defer { try? FileManager.default.removeItem(at: indexRoot) }
        let indexer = RustLibraryIndexer(indexRoot: indexRoot)
        let corpusID = UUID()

        // 取消可能在任何时刻生效；无论是否打断，句柄都不应被永久禁用。
        let task = Task {
            try? await indexer.indexCorpus(
                corpusID: corpusID,
                name: "取消测试",
                rootPath: corpus.path,
                options: CorpusIndexOptions()
            )
        }
        task.cancel()
        _ = await task.result

        let report = try await indexer.indexCorpus(
            corpusID: corpusID,
            name: "取消测试",
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )
        XCTAssertGreaterThanOrEqual(report.filesIndexed, 0)
        let hits = try await indexer.search(corpusID: corpusID, query: "香蕉", limit: 5)
        XCTAssertFalse(hits.isEmpty, "取消后重新索引应可检索")
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
