import XCTest

@testable import DeepSeekChat

/// 跨实例持久化：SQLite 落盘、旧版 state.json 迁移、损坏文件容错、多轮对话一致性。
final class SessionStorePersistenceTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    func testPersistenceAcrossInstances() throws {
        let storeA = harness.makeStore()
        let session = storeA.createSession(title: "持久化")
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "你好"))
        storeA.appendMessage(
            sessionID: session.id,
            ChatMessage(role: .assistant, content: "世界", reasoning: "r")
        )

        let storeB = harness.makeStore()
        let loaded = storeB.sessions
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "持久化")
        let messages = storeB.messages(for: loaded[0].id)
        XCTAssertEqual(messages.map(\.content), ["你好", "世界"])
        XCTAssertEqual(messages.map(\.reasoning), [nil, "r"])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    }

    func testCorruptedSessionsFileLeadsToEmpty() throws {
        try harness.writeFile("sessions.json", Data("not-json{{{".utf8))
        let store = harness.makeStore()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testLegacyStateMigratesIntoSQLite() throws {
        let state: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": UUID().uuidString,
                    "title": "旧会话",
                    "createdAt": 1_000.0,
                    "updatedAt": 1_000.0,
                    "messages": [],
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: state)
        try harness.writeFile("state.json", data)

        let store = harness.makeStore()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].title, "旧会话")
        // 迁移后数据进入 SQLite
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.tempDir.appendingPathComponent("sessions.sqlite").path))
    }

    func testSessionsFileTakesPrecedenceOverMigration() throws {
        let sessions: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "title": "新版会话",
                "createdAt": 1_000.0,
                "updatedAt": 1_000.0,
                "messages": [],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: sessions)
        try harness.writeFile("sessions.json", data)

        let state: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": UUID().uuidString,
                    "title": "旧版会话",
                    "createdAt": 1_000.0,
                    "updatedAt": 1_000.0,
                    "messages": [],
                ]
            ]
        ]
        try harness.writeFile("state.json", try JSONSerialization.data(withJSONObject: state))

        let store = harness.makeStore()
        XCTAssertEqual(store.sessions.map(\.title), ["新版会话"])
    }

    func testMessagesPersistInOrderAcrossInstances() {
        let storeA = harness.makeStore()
        let session = storeA.createSession()
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "1"))
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "2"))
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "3"))

        let storeB = harness.makeStore()
        XCTAssertEqual(storeB.session(id: session.id)?.messages.map(\.content), ["1", "2", "3"])
    }

    func testDeleteSessionRemovesMessagesFromDatabase() {
        let storeA = harness.makeStore()
        let session = storeA.createSession()
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "x"))
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "y"))
        storeA.deleteSession(id: session.id)

        let storeB = harness.makeStore()
        XCTAssertTrue(storeB.sessions.isEmpty)
    }

    func testSyncMessagePersistsToDatabaseAcrossInstances() {
        let storeA = harness.makeStore()
        let session = storeA.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        storeA.appendMessage(sessionID: session.id, message)
        let state = storeA.messageState(for: message)

        state.appendContent("流式")
        state.appendReasoning("推理")
        state.flushPending()
        storeA.syncMessage(state, sessionID: session.id)

        let storeB = harness.makeStore()
        XCTAssertEqual(storeB.session(id: session.id)?.messages[0].content, "流式")
        XCTAssertEqual(storeB.session(id: session.id)?.messages[0].reasoning, "推理")
    }

    /// 模拟「一轮完整对话 + 再次发送」：验证会话与消息在内存和 SQLite 中保持一致。
    func testTwoConversationCyclesRemainConsistent() {
        let store = harness.makeStore()
        let session = store.createSession()

        // 第一轮：用户提问 + 助手流式回答 + 结束
        let u1 = ChatMessage(role: .user, content: "第一问")
        let a1 = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u1)
        store.appendMessage(sessionID: session.id, a1)
        let s1 = store.messageState(for: a1)
        s1.appendContent("回答一")
        s1.flushPending()
        store.commitMessage(s1, sessionID: session.id)

        // 第二轮：再次发送
        let u2 = ChatMessage(role: .user, content: "第二问")
        let a2 = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u2)
        store.appendMessage(sessionID: session.id, a2)
        let s2 = store.messageState(for: a2)
        s2.appendContent("回答二")
        s2.flushPending()
        store.commitMessage(s2, sessionID: session.id)

        let expected = ["第一问", "回答一", "第二问", "回答二"]
        XCTAssertEqual(store.session(id: session.id)?.messages.count, 4)
        XCTAssertEqual(store.session(id: session.id)?.messages.map(\.content), expected)
        // 消息状态对象互不串用
        XCTAssertFalse(s1 === s2)

        // 重新加载后仍然一致（顺序由 position 列保证）
        let storeB = harness.makeStore()
        XCTAssertEqual(storeB.session(id: session.id)?.messages.map(\.content), expected)
    }
}
