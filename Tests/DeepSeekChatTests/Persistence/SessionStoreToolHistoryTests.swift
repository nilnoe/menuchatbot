import GRDB
import XCTest

@testable import DeepSeekChat

/// 工具消息持久化 / 历史回传 / v5 迁移（T2-3c + 通用质量门）。
final class SessionStoreToolHistoryTests: XCTestCase {
    private var tempDir: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreToolHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SessionStore(storageDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testHistoryIncludesToolMessagesAndToolCalls() throws {
        let session = store.createSession(title: "工具会话")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "计算 1+2"))
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    ChatToolCall(
                        id: "call_1",
                        name: "calculator",
                        arguments: #"{"expr":"1+2"}"#
                    )
                ]
            )
        )
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .tool,
                content: "结果：3",
                toolCallID: "call_1",
                toolName: "calculator"
            )
        )

        let history = store.history(for: session.id)
        XCTAssertEqual(history.map(\.role), ["user", "assistant", "tool"])
        let assistant = history[1]
        XCTAssertEqual(assistant.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(assistant.toolCalls?.first?.function.name, "calculator")
        XCTAssertEqual(assistant.toolCalls?.first?.function.arguments, #"{"expr":"1+2"}"#)
        let tool = history[2]
        XCTAssertEqual(tool.toolCallID, "call_1")
        XCTAssertEqual(tool.name, "calculator")
        XCTAssertEqual(tool.content, "结果：3")
    }

    func testToolMessagePersistsAcrossReload() throws {
        let session = store.createSession(title: "持久化")
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .tool,
                content: "结果：42",
                toolCallID: "call_9",
                toolName: "calculator"
            )
        )
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    ChatToolCall(id: "call_9", name: "calculator", arguments: #"{"expr":"6*7"}"#)
                ]
            )
        )

        let reloaded = SessionStore(storageDirectory: tempDir)
        let messages = reloaded.messages(for: session.id)
        let tool = try XCTUnwrap(messages.first(where: { $0.role == .tool }))
        XCTAssertEqual(tool.content, "结果：42")
        XCTAssertEqual(tool.toolCallID, "call_9")
        XCTAssertEqual(tool.toolName, "calculator")
        let assistant = try XCTUnwrap(messages.first(where: { $0.role == .assistant }))
        XCTAssertEqual(assistant.toolCalls?.first?.arguments, #"{"expr":"6*7"}"#)
    }

    func testV5MigrationAddsToolColumns() throws {
        let dbURL = tempDir.appendingPathComponent("migration.sqlite")
        var migrator = SessionStore.migrator
        let queue = try DatabaseQueue(path: dbURL.path)

        // 先迁移到 v4：message 表尚无工具列（旧库形态）。
        try migrator.migrate(queue, upTo: "v4")
        let before = try queue.read { db in
            try db.columns(in: "message").map(\.name)
        }
        XCTAssertFalse(before.contains("toolCallsJSON"))
        XCTAssertFalse(before.contains("toolCallID"))
        XCTAssertFalse(before.contains("toolName"))

        // 继续迁移到最新：v5 应补齐工具列，旧数据保留。
        try migrator.migrate(queue)
        let after = try queue.read { db in
            try db.columns(in: "message").map(\.name)
        }
        XCTAssertTrue(after.contains("toolCallsJSON"))
        XCTAssertTrue(after.contains("toolCallID"))
        XCTAssertTrue(after.contains("toolName"))
    }
}
