import DeepSeekChatIndexing
import XCTest

@testable import DeepSeekChat

/// LibraryIndexModel（Tier 3-5）：状态发布、单库重新索引、取消、移除。
@MainActor
final class LibraryIndexModelTests: XCTestCase {
    private var corpusDir: URL!
    private var corpus: LibraryCorpus!

    override func setUpWithError() throws {
        corpusDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-index-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusDir, withIntermediateDirectories: true)
        corpus = LibraryCorpus(
            id: UUID(),
            name: "测试资料库",
            path: corpusDir.path,
            isEnabled: true,
            bookmarkData: nil
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: corpusDir)
    }

    private func waitForStatus(
        _ model: LibraryIndexModel,
        _ corpusID: UUID,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.status(for: corpusID)?.isIndexing != false {
            if Date() >= deadline {
                XCTFail("等待索引状态超时")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testReindexUpdatesStatusAndIgnoresDuplicate() async throws {
        try "苹果种植指南".write(
            to: corpusDir.appendingPathComponent("a.md"),
            atomically: true,
            encoding: .utf8
        )
        let model = LibraryIndexModel(
            indexer: MockLibraryIndexer(),
            corporaProvider: { [self] in
                [corpus!]
            })

        model.reindex(corpus: corpus)
        XCTAssertTrue(model.status(for: corpus.id)?.isIndexing == true)
        model.reindex(corpus: corpus)  // 幂等：进行中重复调用忽略
        try await waitForStatus(model, corpus.id)

        let status = model.status(for: corpus.id)
        XCTAssertEqual(status?.fileCount, 1)
        XCTAssertEqual(status?.chunkCount, 1)
        XCTAssertNil(status?.lastError)
        XCTAssertNotNil(status?.lastIndexedAt)
        XCTAssertFalse(model.isAnyIndexing)
    }

    func testCancelAllEventuallyStopsIndexing() async throws {
        for index in 0..<50 {
            try String(repeating: "文档 \(index) 内容：苹果香蕉", count: 40).write(
                to: corpusDir.appendingPathComponent("f\(index).md"),
                atomically: true,
                encoding: .utf8
            )
        }
        let model = LibraryIndexModel(
            indexer: MockLibraryIndexer(),
            corporaProvider: { [self] in
                [corpus!]
            })
        model.reindex(corpus: corpus)
        model.cancelAll()
        try await waitForStatus(model, corpus.id)
        XCTAssertFalse(model.isAnyIndexing, "取消后不应再显示索引中")
    }

    func testRemoveClearsStatusAndIndex() async throws {
        try "内容".write(
            to: corpusDir.appendingPathComponent("a.md"),
            atomically: true,
            encoding: .utf8
        )
        let model = LibraryIndexModel(
            indexer: MockLibraryIndexer(),
            corporaProvider: { [self] in
                [corpus!]
            })
        model.reindex(corpus: corpus)
        try await waitForStatus(model, corpus.id)

        await model.remove(corpusID: corpus.id)
        XCTAssertNil(model.status(for: corpus.id))
        XCTAssertFalse(model.isAnyIndexing)
    }

    func testRefreshStatusesLoadsExistingIndex() async throws {
        try "苹果种植指南".write(
            to: corpusDir.appendingPathComponent("a.md"),
            atomically: true,
            encoding: .utf8
        )
        let indexer = MockLibraryIndexer()
        _ = try await indexer.indexCorpus(
            corpusID: corpus.id,
            name: corpus.name,
            rootPath: corpus.path,
            options: CorpusIndexOptions()
        )
        let model = LibraryIndexModel(
            indexer: indexer,
            corporaProvider: { [self] in
                [corpus!]
            })
        await model.refreshStatuses()

        let status = model.status(for: corpus.id)
        XCTAssertEqual(status?.fileCount, 1)
        XCTAssertEqual(status?.chunkCount, 1)
        XCTAssertNotNil(status?.lastIndexedAt)
    }
}
