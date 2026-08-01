import XCTest

@testable import DeepSeekChat

/// 消息操作：追加 / 更新 / 单条删除，以及 history 查询。
final class SessionStoreMessageTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    // MARK: - 消息操作

    func testAppendMessageUpdatesUpdatedAt() {
        let store = harness.makeStore()
        let session = store.createSession()
        store.renameSession(id: session.id, title: "t")
        let before = store.session(id: session.id)?.updatedAt ?? .distantPast
        Thread.sleep(forTimeInterval: 0.01)
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "hi"))
        let after = store.session(id: session.id)?.updatedAt
        XCTAssertGreaterThan(after ?? .distantPast, before)
        XCTAssertEqual(store.session(id: session.id)?.messages.count, 1)
    }

    func testAppendMessageUnknownSessionNoop() {
        let store = harness.makeStore()
        store.appendMessage(sessionID: UUID(), ChatMessage(role: .user, content: "x"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testUpdateMessageAppendsContent() {
        let store = harness.makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)

        store.updateMessage(sessionID: session.id, messageID: message.id) { $0.content += "流式" }
        store.updateMessage(sessionID: session.id, messageID: message.id) { $0.content += "增量" }
        XCTAssertEqual(store.session(id: session.id)?.messages[0].content, "流式增量")
    }

    func testUpdateMessageSetsErrorAndSources() {
        let store = harness.makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)

        store.updateMessage(sessionID: session.id, messageID: message.id) {
            $0.content = "出错了"
            $0.isError = true
            $0.sources = [Source(title: "s", url: "https://s.com")]
        }
        let updated = store.session(id: session.id)?.messages[0]
        XCTAssertEqual(updated?.content, "出错了")
        XCTAssertTrue(updated?.isError ?? false)
        XCTAssertEqual(updated?.sources?.first?.url, "https://s.com")
    }

    func testUpdateMessageUnknownIDsNoop() {
        let store = harness.makeStore()
        let session = store.createSession()
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "a"))
        store.updateMessage(sessionID: session.id, messageID: UUID()) { $0.content = "x" }
        store.updateMessage(sessionID: UUID(), messageID: UUID()) { $0.content = "x" }
        XCTAssertEqual(store.session(id: session.id)?.messages[0].content, "a")
    }

    // MARK: - 单条消息删除

    func testRemoveMessageRemovesFromMemory() {
        let store = harness.makeStore()
        let session = store.createSession(title: "删除")
        let first = ChatMessage(role: .user, content: "第一条")
        let second = ChatMessage(role: .assistant, content: "第二条")
        store.appendMessage(sessionID: session.id, first)
        store.appendMessage(sessionID: session.id, second)

        store.removeMessage(sessionID: session.id, messageID: first.id)

        XCTAssertEqual(store.session(id: session.id)?.messages.map(\.content), ["第二条"])
        XCTAssertEqual(store.session(id: session.id)?.messages.map(\.id), [second.id])
    }

    func testRemoveMessagePersistsAcrossInstances() {
        let store = harness.makeStore()
        let session = store.createSession(title: "删除持久化")
        for content in ["A", "B", "C"] {
            store.appendMessage(
                sessionID: session.id,
                ChatMessage(role: .user, content: content)
            )
        }
        let messages = store.session(id: session.id)!.messages
        // 删除中间一条，position 应重排连续
        store.removeMessage(sessionID: session.id, messageID: messages[1].id)

        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.session(id: session.id)?.messages.map(\.content), ["A", "C"])
    }

    func testRemoveMessageUnknownIDsNoop() {
        let store = harness.makeStore()
        let session = store.createSession()
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "a"))
        store.removeMessage(sessionID: session.id, messageID: UUID())
        store.removeMessage(sessionID: UUID(), messageID: UUID())
        XCTAssertEqual(store.session(id: session.id)?.messages.map(\.content), ["a"])
    }

    // MARK: - history

    func testHistoryFiltersEmptyContentAndMapsRoles() {
        let store = harness.makeStore()
        let session = store.createSession()
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "问题"))
        store.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: ""))
        store.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "回答"))

        let history = store.history(for: session.id)
        XCTAssertEqual(history.map(\.role), ["user", "assistant"])
        XCTAssertEqual(history.map(\.content), ["问题", "回答"])
    }

    func testHistoryEmptyForUnknownSession() {
        let store = harness.makeStore()
        XCTAssertTrue(store.history(for: UUID()).isEmpty)
    }

    func testSessionNilForUnknownID() {
        let store = harness.makeStore()
        XCTAssertNil(store.session(id: UUID()))
    }
}
