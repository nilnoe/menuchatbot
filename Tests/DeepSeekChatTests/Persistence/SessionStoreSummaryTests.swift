import XCTest

@testable import DeepSeekChat

/// 会话列表项（SessionSummary）：条数 / token 合计 / 来源标记的维护与持久化，
/// 以及消息惰性加载 / 物化一致性（Tier 1-1，ACCEPTANCE T1-1a / T1-1c）。
final class SessionStoreSummaryTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    func testSummaryTracksMessageCountAndTokens() {
        let store = harness.makeStore()
        let session = store.createSession(title: "统计")

        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "a"))
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "b",
                usage: TokenUsage(
                    promptTokens: 30, cachedTokens: 0, completionTokens: 8, totalTokens: 38)
            )
        )

        let summary = store.summary(id: session.id)
        XCTAssertEqual(summary?.messageCount, 2)
        XCTAssertEqual(summary?.totalTokens, 38)
    }

    func testSummaryTracksLastMessageHasSources() {
        let store = harness.makeStore()
        let session = store.createSession(title: "来源")
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(role: .assistant, content: "带来源", sources: [])
        )
        XCTAssertFalse(store.summary(id: session.id)?.lastMessageHasSources ?? true)

        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "联网",
                sources: [Source(title: "s", url: "https://example.com")]
            )
        )
        XCTAssertTrue(store.summary(id: session.id)?.lastMessageHasSources ?? false)
    }

    func testSummaryPersistsAcrossReload() {
        let store = harness.makeStore()
        let session = store.createSession(title: "持久化")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "x"))
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "y",
                sources: [Source(title: "s", url: "https://example.com")],
                usage: TokenUsage(
                    promptTokens: 10, cachedTokens: 0, completionTokens: 5, totalTokens: 15)
            )
        )

        let reloaded = harness.makeStore()
        let summary = reloaded.summary(id: session.id)
        XCTAssertEqual(summary?.messageCount, 2)
        XCTAssertEqual(summary?.totalTokens, 15)
        XCTAssertTrue(summary?.lastMessageHasSources ?? false)
        XCTAssertEqual(reloaded.messages(for: session.id).count, 2)
    }

    func testMessagesLazyLoadMatchesMaterializedSession() {
        let store = harness.makeStore()
        let session = store.createSession(title: "惰性")
        for content in ["1", "2", "3"] {
            store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: content))
        }

        let materialized = store.session(id: session.id)?.messages ?? []
        let lazy = store.messages(for: session.id)
        XCTAssertEqual(lazy.map(\.content), materialized.map(\.content))
        XCTAssertEqual(lazy.map(\.id), materialized.map(\.id))
    }

    func testSummaryUpdateMessageAdjustsTokens() {
        let store = harness.makeStore()
        let session = store.createSession(title: "更新")
        let message = ChatMessage(
            role: .assistant,
            content: "",
            usage: TokenUsage(
                promptTokens: 30, cachedTokens: 0, completionTokens: 8, totalTokens: 38)
        )
        store.appendMessage(sessionID: session.id, message)

        store.updateMessage(sessionID: session.id, messageID: message.id) {
            $0.usage = TokenUsage(
                promptTokens: 30, cachedTokens: 0, completionTokens: 12, totalTokens: 42)
        }
        XCTAssertEqual(store.summary(id: session.id)?.totalTokens, 42)
    }
}
