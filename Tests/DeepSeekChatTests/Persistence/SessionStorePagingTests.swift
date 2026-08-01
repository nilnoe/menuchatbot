import XCTest

@testable import DeepSeekChat

/// 消息分页：尾部加载 + 上翻增量加载（Tier 1-1e，ACCEPTANCE T1-1e）。
final class SessionStorePagingTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    /// 造 300 条消息（content = "0"..."299"，position 与顺序一致）。
    private func makeSessionWith300Messages() -> (SessionStore, UUID) {
        let store = harness.makeStore()
        let session = store.createSession(title: "分页")
        for index in 0..<300 {
            store.appendMessage(
                sessionID: session.id,
                ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "\(index)")
            )
        }
        return (store, session.id)
    }

    func testTailReturnsNewestLimited() {
        let (store, id) = makeSessionWith300Messages()
        let tail = store.messagesTail(for: id, limit: 200)
        XCTAssertEqual(tail.count, 200)
        XCTAssertEqual(tail.first?.content, "100")
        XCTAssertEqual(tail.last?.content, "299")
    }

    func testTailForShortSessionReturnsAll() {
        let store = harness.makeStore()
        let session = store.createSession()
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "a"))
        let tail = store.messagesTail(for: session.id, limit: 200)
        XCTAssertEqual(tail.map(\.content), ["a"])
    }

    func testMessagesBeforeReturnsOlderPage() {
        let (store, id) = makeSessionWith300Messages()
        let tail = store.messagesTail(for: id, limit: 200)
        let older = store.messagesBefore(tail.first!, sessionID: id, limit: 100)
        XCTAssertEqual(older.count, 100)
        XCTAssertEqual(older.first?.content, "0")
        XCTAssertEqual(older.last?.content, "99")
    }

    func testMessagesBeforeAtHeadReturnsEmpty() {
        let (store, id) = makeSessionWith300Messages()
        let tail = store.messagesTail(for: id, limit: 300)
        let older = store.messagesBefore(tail.first!, sessionID: id, limit: 100)
        XCTAssertTrue(older.isEmpty)
    }

    func testMessagesBeforeUnknownCursorReturnsEmpty() {
        let (store, id) = makeSessionWith300Messages()
        let ghost = ChatMessage(role: .user, content: "不存在")
        XCTAssertTrue(store.messagesBefore(ghost, sessionID: id, limit: 100).isEmpty)
    }
}
