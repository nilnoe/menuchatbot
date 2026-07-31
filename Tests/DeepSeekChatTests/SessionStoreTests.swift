import XCTest
@testable import DeepSeekChat

final class SessionStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> SessionStore {
        SessionStore(storageDirectory: tempDir, saveDelay: .zero)
    }

    private func writeFile(_ name: String, _ data: Data) throws {
        try data.write(to: tempDir.appendingPathComponent(name))
    }

    // MARK: - 基础操作

    func testCreateSessionInsertsAtFront() {
        let store = makeStore()
        let first = store.createSession(title: "A")
        let second = store.createSession(title: "B")
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions[0].id, second.id)
        XCTAssertEqual(store.sessions[1].id, first.id)
        XCTAssertTrue(second.messages.isEmpty)
    }

    func testCreateSessionDefaultsTitle() {
        let store = makeStore()
        let session = store.createSession()
        XCTAssertEqual(session.title, "新对话")
    }

    func testRenameSession() {
        let store = makeStore()
        let session = store.createSession(title: "旧")
        store.renameSession(id: session.id, title: "新标题")
        XCTAssertEqual(store.session(id: session.id)?.title, "新标题")
    }

    func testRenameUnknownIDNoop() {
        let store = makeStore()
        store.renameSession(id: UUID(), title: "x")
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testDeleteSession() {
        let store = makeStore()
        let a = store.createSession()
        let b = store.createSession()
        store.deleteSession(id: a.id)
        XCTAssertEqual(store.sessions.map(\.id), [b.id])
    }

    func testDeleteUnknownIDNoop() {
        let store = makeStore()
        _ = store.createSession()
        store.deleteSession(id: UUID())
        XCTAssertEqual(store.sessions.count, 1)
    }

    // MARK: - 消息操作

    func testAppendMessageUpdatesUpdatedAt() {
        let store = makeStore()
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
        let store = makeStore()
        store.appendMessage(sessionID: UUID(), ChatMessage(role: .user, content: "x"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testUpdateMessageAppendsContent() {
        let store = makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)

        store.updateMessage(sessionID: session.id, messageID: message.id) { $0.content += "流式" }
        store.updateMessage(sessionID: session.id, messageID: message.id) { $0.content += "增量" }
        XCTAssertEqual(store.session(id: session.id)?.messages[0].content, "流式增量")
    }

    func testUpdateMessageSetsErrorAndSources() {
        let store = makeStore()
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
        let store = makeStore()
        let session = store.createSession()
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "a"))
        store.updateMessage(sessionID: session.id, messageID: UUID()) { $0.content = "x" }
        store.updateMessage(sessionID: UUID(), messageID: UUID()) { $0.content = "x" }
        XCTAssertEqual(store.session(id: session.id)?.messages[0].content, "a")
    }

    // MARK: - 消息状态（流式性能）

    func testMessageStateIsSharedPerMessage() {
        let store = makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "初始")
        store.appendMessage(sessionID: session.id, message)

        let first = store.messageState(for: message)
        let second = store.messageState(for: message)
        XCTAssertTrue(first === second, "同一消息应复用同一个状态对象")
        XCTAssertEqual(first.content, "初始")
        XCTAssertEqual(first.role, .assistant)
    }

    func testSyncMessageWritesThroughWithoutPublishing() {
        let store = makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)

        var publishCount = 0
        let cancellable = store.objectWillChange.sink { publishCount += 1 }
        _ = cancellable

        state.appendContent("流式内容")
        state.appendReasoning("推理片段")
        state.setSearching(true)
        state.flushPending()
        store.syncMessage(state, sessionID: session.id)

        XCTAssertEqual(publishCount, 0, "流式写回不应触发整树刷新")
        let stored = store.session(id: session.id)?.messages[0]
        XCTAssertEqual(stored?.content, "流式内容")
        XCTAssertEqual(stored?.reasoning, "推理片段")
        XCTAssertTrue(stored?.isSearching ?? false)
    }

    func testCommitMessagePublishesOnceAndFlushes() {
        let store = makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)

        var publishCount = 0
        let cancellable = store.objectWillChange.sink { publishCount += 1 }
        _ = cancellable

        state.appendContent("最终内容")
        state.flushPending()
        store.commitMessage(state, sessionID: session.id)

        XCTAssertEqual(publishCount, 1, "流式结束只应发布一次")
        let stored = store.session(id: session.id)?.messages[0]
        XCTAssertEqual(stored?.content, "最终内容")
        XCTAssertFalse(stored?.isError ?? true)
    }

    func testMessageStateCoalescesDeltasUntilFlush() {
        let message = ChatMessage(role: .assistant, content: "")
        let state = MessageState(message: message)
        var publishCount = 0
        let cancellable = state.objectWillChange.sink { publishCount += 1 }
        _ = cancellable

        state.appendContent("你")
        state.appendContent("好")
        state.appendReasoning("深")
        state.appendReasoning("思")

        XCTAssertEqual(state.content, "", "聚合前不应发布到 UI")
        // 第一个分片触发一次 isStreaming 标记（一次性，后续分片不再发布）。
        XCTAssertEqual(publishCount, 1, "分片只进缓冲，仅流式标记发布一次")

        state.flushPending()
        XCTAssertEqual(state.content, "你好")
        XCTAssertEqual(state.reasoning, "深思")
        // content 与 reasoning 两个 @Published 字段各触发一次；
        // 同一 runloop 内 SwiftUI 会合并为一次视图更新。
        XCTAssertEqual(publishCount, 3, "发布 = 流式标记 1 次 + flush 字段 2 次")
        XCTAssertFalse(state.hasPendingChanges)
    }

    func testMessageStateErrorDiscardsPendingDeltas() {
        let message = ChatMessage(role: .assistant, content: "")
        let state = MessageState(message: message)
        state.appendContent("部分内容")
        state.setError("出错了")

        XCTAssertEqual(state.content, "出错了")
        XCTAssertTrue(state.isError)

        state.flushPending()
        XCTAssertEqual(state.content, "出错了", "flush 不应把已丢弃的增量加回")
    }

    func testMessageStateTracksStreamingLifecycle() {
        let message = ChatMessage(role: .assistant, content: "")
        let state = MessageState(message: message)
        XCTAssertFalse(state.isStreaming)

        state.appendContent("a")
        XCTAssertTrue(state.isStreaming, "收到分片后应标记为流式")
        state.appendReasoning("r")
        XCTAssertTrue(state.isStreaming)

        state.flushPending()
        XCTAssertTrue(state.isStreaming, "聚合 flush 不结束流式")

        state.markStreamEnded()
        XCTAssertFalse(state.isStreaming, "结束标记后恢复非流式渲染")
    }

    // MARK: - history

    func testHistoryFiltersEmptyContentAndMapsRoles() {
        let store = makeStore()
        let session = store.createSession()
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "问题"))
        store.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: ""))
        store.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "回答"))

        let history = store.history(for: session.id)
        XCTAssertEqual(history.map(\.role), ["user", "assistant"])
        XCTAssertEqual(history.map(\.content), ["问题", "回答"])
    }

    func testHistoryEmptyForUnknownSession() {
        let store = makeStore()
        XCTAssertTrue(store.history(for: UUID()).isEmpty)
    }

    func testSessionNilForUnknownID() {
        let store = makeStore()
        XCTAssertNil(store.session(id: UUID()))
    }

    // MARK: - 持久化

    func testPersistenceAcrossInstances() throws {
        let storeA = makeStore()
        let session = storeA.createSession(title: "持久化")
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "你好"))
        storeA.appendMessage(
            sessionID: session.id,
            ChatMessage(role: .assistant, content: "世界", reasoning: "r")
        )

        let storeB = makeStore()
        let loaded = storeB.sessions
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "持久化")
        XCTAssertEqual(loaded[0].messages.map(\.content), ["你好", "世界"])
        XCTAssertEqual(loaded[0].messages.map(\.reasoning), [nil, "r"])
        XCTAssertEqual(loaded[0].messages.map(\.role), [.user, .assistant])
    }

    func testCorruptedSessionsFileLeadsToEmpty() throws {
        try writeFile("sessions.json", Data("not-json{{{".utf8))
        let store = makeStore()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testLegacyStateMigratesIntoSQLite() throws {
        let state: [String: Any] = [
            "deepseek-chat.sessions.v1": [[
                "id": UUID().uuidString,
                "title": "旧会话",
                "createdAt": 1_000.0,
                "updatedAt": 1_000.0,
                "messages": []
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: state)
        try writeFile("state.json", data)

        let store = makeStore()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].title, "旧会话")
        // 迁移后数据进入 SQLite
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("sessions.sqlite").path))
    }

    func testSessionsFileTakesPrecedenceOverMigration() throws {
        let sessions: [[String: Any]] = [[
            "id": UUID().uuidString,
            "title": "新版会话",
            "createdAt": 1_000.0,
            "updatedAt": 1_000.0,
            "messages": []
        ]]
        let data = try JSONSerialization.data(withJSONObject: sessions)
        try writeFile("sessions.json", data)

        let state: [String: Any] = [
            "deepseek-chat.sessions.v1": [[
                "id": UUID().uuidString,
                "title": "旧版会话",
                "createdAt": 1_000.0,
                "updatedAt": 1_000.0,
                "messages": []
            ]]
        ]
        try writeFile("state.json", try JSONSerialization.data(withJSONObject: state))

        let store = makeStore()
        XCTAssertEqual(store.sessions.map(\.title), ["新版会话"])
    }

    func testMessagesPersistInOrderAcrossInstances() {
        let storeA = makeStore()
        let session = storeA.createSession()
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "1"))
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "2"))
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "3"))

        let storeB = makeStore()
        XCTAssertEqual(storeB.session(id: session.id)?.messages.map(\.content), ["1", "2", "3"])
    }

    func testDeleteSessionRemovesMessagesFromDatabase() {
        let storeA = makeStore()
        let session = storeA.createSession()
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "x"))
        storeA.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "y"))
        storeA.deleteSession(id: session.id)

        let storeB = makeStore()
        XCTAssertTrue(storeB.sessions.isEmpty)
    }

    func testSyncMessagePersistsToDatabaseAcrossInstances() {
        let storeA = makeStore()
        let session = storeA.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        storeA.appendMessage(sessionID: session.id, message)
        let state = storeA.messageState(for: message)

        state.appendContent("流式")
        state.appendReasoning("推理")
        state.flushPending()
        storeA.syncMessage(state, sessionID: session.id)

        let storeB = makeStore()
        XCTAssertEqual(storeB.session(id: session.id)?.messages[0].content, "流式")
        XCTAssertEqual(storeB.session(id: session.id)?.messages[0].reasoning, "推理")
    }

    /// 模拟「一轮完整对话 + 再次发送」：验证会话与消息在内存和 SQLite 中保持一致。
    func testTwoConversationCyclesRemainConsistent() {
        let store = makeStore()
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
        let storeB = makeStore()
        XCTAssertEqual(storeB.session(id: session.id)?.messages.map(\.content), expected)
    }
}
