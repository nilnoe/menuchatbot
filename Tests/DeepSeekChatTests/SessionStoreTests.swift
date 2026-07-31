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
        XCTAssertEqual(storeB.sessions, storeA.sessions)
        XCTAssertEqual(storeB.sessions.count, 1)
        XCTAssertEqual(storeB.sessions[0].messages.count, 2)
        XCTAssertEqual(storeB.sessions[0].messages[1].reasoning, "r")
    }

    func testCorruptedSessionsFileLeadsToEmpty() throws {
        try writeFile("sessions.json", Data("not-json{{{".utf8))
        let store = makeStore()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testMigrationFallbackWhenSessionsMissing() throws {
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
        // 迁移后立即写出新文件
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("sessions.json").path))
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
}
