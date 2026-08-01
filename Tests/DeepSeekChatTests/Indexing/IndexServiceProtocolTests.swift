import XCTest

@testable import DeepSeekChatIndexing

/// IndexService 协议行为测试（MockIndexService，与 Rust 实现共享契约）。
/// 上层业务只依赖协议，换实现不动这些测试（DESIGN_RUST_CORE §8）。
final class IndexServiceProtocolTests: XCTestCase {
    private func makeDoc(
        id: String,
        content: String,
        namespace: String = "history",
        sessionID: String = "s1"
    ) -> IndexableMessage {
        IndexableMessage(
            id: id,
            sessionID: sessionID,
            position: 0,
            contentHash: "hash-\(id)",
            content: content,
            namespace: namespace
        )
    }

    func testUpsertSearchDeleteRoundtrip() async throws {
        let service = MockIndexService()
        let firstID = UUID()
        let secondID = UUID()
        try await service.upsert(makeDoc(id: firstID.uuidString, content: "香蕉牛奶"))
        try await service.upsert(makeDoc(id: secondID.uuidString, content: "苹果派"))

        let hits = try await service.search("香蕉", scope: .history, limit: 10)
        XCTAssertEqual(hits.map(\.id), [firstID.uuidString])
        XCTAssertEqual(hits.first?.score, 1)

        try await service.delete(messageID: firstID, sessionID: UUID())
        let afterDelete = try await service.search("香蕉", scope: .history, limit: 10)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testSearchRanksByTokenHitsAndRespectsLimit() async throws {
        let service = MockIndexService()
        for index in 0..<20 {
            try await service.upsert(
                makeDoc(id: "m\(index)", content: "Swift Swift \(index)")
            )
        }
        let hits = try await service.search("swift", scope: .history, limit: 5)
        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(hits.first?.score, 2, "命中次数越多排名越前")
    }

    func testSearchNamespaceIsolation() async throws {
        let service = MockIndexService()
        try await service.upsert(makeDoc(id: "h1", content: "苹果", namespace: "history"))
        try await service.upsert(makeDoc(id: "l1", content: "苹果", namespace: "library"))

        let history = try await service.search("苹果", scope: .history, limit: 10)
        let library = try await service.search("苹果", scope: .library("资料库"), limit: 10)
        XCTAssertEqual(history.map(\.id), ["h1"])
        XCTAssertEqual(library.map(\.id), ["l1"])
    }

    func testUpsertIsIdempotent() async throws {
        let service = MockIndexService()
        try await service.upsert(makeDoc(id: "m1", content: "旧内容"))
        try await service.upsert(makeDoc(id: "m1", content: "新内容"))
        let count = await service.documentCount
        XCTAssertEqual(count, 1)
        let hits = try await service.search("新内容", scope: .history, limit: 10)
        XCTAssertEqual(hits.map(\.id), ["m1"])
    }

    func testUnavailableStateThrowsForAllOperations() async throws {
        let service = MockIndexService(state: .unavailable("Rust 核心不可用"))
        await assertThrows(try await service.upsert(makeDoc(id: "m1", content: "x")))
        await assertThrows(
            try await service.search("x", scope: .history, limit: 10)
        )
        await assertThrows(
            try await service.delete(messageID: UUID(), sessionID: UUID())
        )
        await assertThrows(try await service.rebuildIfNeeded())
        let state = await service.state
        XCTAssertEqual(state, .unavailable("Rust 核心不可用"))
    }

    func testRebuildIfNeededIsNoopForMock() async throws {
        let service = MockIndexService()
        try await service.upsert(makeDoc(id: "m1", content: "内容"))
        try await service.rebuildIfNeeded()
        let count = await service.documentCount
        XCTAssertEqual(count, 1, "内存实现 rebuild 不应清空")
    }
}

extension XCTestCase {
    /// 异步抛错断言（XCTAssertThrowsError 不直接支持 async）。
    fileprivate func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("应抛出错误：\(message)", file: file, line: line)
        } catch {
            // 预期抛出。
        }
    }
}
