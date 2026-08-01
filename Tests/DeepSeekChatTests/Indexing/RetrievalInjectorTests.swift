import DeepSeekChatIndexing
import XCTest

@testable import DeepSeekChat

/// 可控假索引器：直接注入检索命中，隔离注入器逻辑测试。
actor FakeLibraryIndexer: LibraryIndexing {
    private var hitsByCorpus: [UUID: [SearchHit]] = [:]

    func seed(corpusID: UUID, hits: [SearchHit]) {
        hitsByCorpus[corpusID] = hits
    }

    func indexCorpus(
        corpusID: UUID,
        name: String,
        rootPath: String,
        options: CorpusIndexOptions
    ) async throws -> CorpusIndexReport {
        CorpusIndexReport(corpusID: corpusID.uuidString, corpusName: name)
    }

    func search(corpusID: UUID, query: String, limit: Int) async throws -> [SearchHit] {
        Array((hitsByCorpus[corpusID] ?? []).prefix(limit))
    }

    func snapshot(corpusID: UUID) async -> LibrarySnapshot {
        LibrarySnapshot(corpusID: corpusID.uuidString, ready: true)
    }

    func removeCorpus(corpusID: UUID) async throws {}

    func cancelIndexing() async {}
}

/// 检索注入器（T3-3b）：预算约束、按文件去重、Source 复用、空结果不注入。
final class RetrievalInjectorTests: XCTestCase {
    private func makeCorpus(id: UUID = UUID(), name: String = "资料库一", enabled: Bool = true)
        -> LibraryCorpus
    {
        LibraryCorpus(
            id: id, name: name, path: "/docs/\(name)", isEnabled: enabled, bookmarkData: nil)
    }

    func testRetrieveInjectsContextAndSources() async {
        let indexer = FakeLibraryIndexer()
        let corpus = makeCorpus()
        await indexer.seed(
            corpusID: corpus.id,
            hits: [
                SearchHit(
                    id: "c1",
                    score: 800,
                    content: "苹果种植指南：施肥与浇水",
                    path: "/docs/资料库一/guide.md"
                )
            ]
        )
        let injector = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [corpus] },
            tokenBudget: 6_000,
            topKPerCorpus: 4
        )

        let result = await injector.retrieve(for: "苹果怎么种")
        XCTAssertTrue(result.context.contains("资料库一"))
        XCTAssertTrue(result.context.contains("苹果种植指南"))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].title, "guide.md", "标题 = 文件名")
        XCTAssertEqual(result.sources[0].url, "/docs/资料库一/guide.md", "url = 路径")
    }

    func testRetrieveDedupesByFileKeepingBestScore() async {
        let indexer = FakeLibraryIndexer()
        let corpus = makeCorpus()
        await indexer.seed(
            corpusID: corpus.id,
            hits: [
                SearchHit(
                    id: "c1",
                    score: 900,
                    content: "高分内容",
                    path: "/docs/a.md"
                ),
                SearchHit(
                    id: "c2",
                    score: 100,
                    content: "低分内容",
                    path: "/docs/a.md"
                ),
            ]
        )
        let injector = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [corpus] },
            tokenBudget: 6_000,
            topKPerCorpus: 4
        )

        let result = await injector.retrieve(for: "苹果")
        XCTAssertEqual(result.sources.count, 1, "同文件应只保留一个来源")
        XCTAssertTrue(result.context.contains("高分内容"))
        XCTAssertFalse(result.context.contains("低分内容"))
    }

    func testRetrieveRespectsTokenBudget() async {
        let indexer = FakeLibraryIndexer()
        let corpus = makeCorpus()
        let longContent = String(repeating: "苹果种植要点与浇水施肥注意事项", count: 120)
        await indexer.seed(
            corpusID: corpus.id,
            hits: [
                SearchHit(id: "c1", score: 800, content: longContent, path: "/docs/big.md")
            ]
        )

        // 预算极小 → 低于阈值不注入（T3-3b）。
        let tiny = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [corpus] },
            tokenBudget: 50,
            topKPerCorpus: 4
        )
        let tinyResult = await tiny.retrieve(for: "苹果")
        XCTAssertTrue(tinyResult.context.isEmpty)
        XCTAssertTrue(tinyResult.sources.isEmpty)

        // 预算足够 → 正常注入。
        let enough = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [corpus] },
            tokenBudget: 6_000,
            topKPerCorpus: 4
        )
        let enoughResult = await enough.retrieve(for: "苹果")
        XCTAssertFalse(enoughResult.context.isEmpty)
        XCTAssertEqual(enoughResult.sources.count, 1)
    }

    func testRetrieveEmptyWhenNoEnabledCorporaOrNoHits() async {
        let indexer = FakeLibraryIndexer()
        let disabled = makeCorpus(enabled: false)
        let injector = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [disabled] },
            tokenBudget: 6_000,
            topKPerCorpus: 4
        )
        let disabledResult = await injector.retrieve(for: "苹果")
        XCTAssertTrue(disabledResult.context.isEmpty)
        XCTAssertTrue(disabledResult.sources.isEmpty)

        let enabled = makeCorpus()
        let emptyInjector = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [enabled] },
            tokenBudget: 6_000,
            topKPerCorpus: 4
        )
        let emptyResult = await emptyInjector.retrieve(for: "没有任何命中")
        XCTAssertTrue(emptyResult.context.isEmpty, "无命中不注入")
        XCTAssertTrue(emptyResult.sources.isEmpty)

        let blankResult = await emptyInjector.retrieve(for: "   ")
        XCTAssertTrue(blankResult.context.isEmpty)
    }

    func testRetrieveMergesSourcesAcrossCorpora() async {
        let indexer = FakeLibraryIndexer()
        let first = makeCorpus(name: "工作笔记")
        let second = makeCorpus(name: "技术文档")
        await indexer.seed(
            corpusID: first.id,
            hits: [
                SearchHit(id: "c1", score: 800, content: "工作内容", path: "/w/notes.md")
            ]
        )
        await indexer.seed(
            corpusID: second.id,
            hits: [
                SearchHit(id: "c2", score: 700, content: "技术要点", path: "/t/docs.md")
            ]
        )
        let injector = LibraryRetrievalInjector(
            indexer: indexer,
            corporaProvider: { [first, second] },
            tokenBudget: 6_000,
            topKPerCorpus: 4
        )

        let result = await injector.retrieve(for: "要点")
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertTrue(result.context.contains("工作笔记"))
        XCTAssertTrue(result.context.contains("技术文档"))
    }
}
