import XCTest

@testable import DeepSeekChat

/// 导入 / 导出：往返一致性、ID 重建、单会话导出、空库、非法输入回滚。
final class SessionStoreImportExportTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    func testExportImportRoundTrip() throws {
        let source = harness.makeStore()
        let session = source.createSession(title: "导出测试")
        source.appendMessage(
            sessionID: session.id,
            ChatMessage(role: .user, content: "你好")
        )
        source.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "世界",
                reasoning: "先想想",
                sources: [Source(title: "来源", url: "https://example.com")]
            )
        )

        let data = try source.exportJSON()
        let target = harness.makeStore()
        let result = try target.importJSON(data)

        XCTAssertEqual(result.importedSessions, 1)
        XCTAssertEqual(result.importedMessages, 2)
        let imported = try XCTUnwrap(target.sessions.first)
        XCTAssertEqual(imported.title, "导出测试")
        let importedMessages = target.messages(for: imported.id)
        XCTAssertEqual(importedMessages.count, 2)
        XCTAssertEqual(importedMessages[0].content, "你好")
        XCTAssertEqual(importedMessages[1].content, "世界")
        XCTAssertEqual(importedMessages[1].reasoning, "先想想")
        XCTAssertEqual(
            importedMessages[1].sources, [Source(title: "来源", url: "https://example.com")])
        // 导入会重新生成 ID，不覆盖原数据
        XCTAssertNotEqual(imported.id, session.id)
        let sourceMessages = try XCTUnwrap(source.session(id: session.id)?.messages)
        XCTAssertFalse(importedMessages.map(\.id).contains(sourceMessages[0].id))
    }

    func testImportRegeneratesIDsToAvoidCollisions() throws {
        let store = harness.makeStore()
        let session = store.createSession(title: "A")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "hi"))
        let data = try store.exportJSON()

        _ = try store.importJSON(data)
        _ = try store.importJSON(data)

        XCTAssertEqual(store.sessions.count, 3)
        let sessionIDs = store.sessions.map(\.id)
        XCTAssertEqual(Set(sessionIDs).count, sessionIDs.count)
        let messageIDs = store.sessions.flatMap { store.messages(for: $0.id) }.map(\.id)
        XCTAssertEqual(Set(messageIDs).count, messageIDs.count)
    }

    func testImportedSessionsPersistToDatabase() throws {
        let source = harness.makeStore()
        let session = source.createSession(title: "持久化")
        source.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "x"))
        let data = try source.exportJSON()

        _ = try harness.makeStore().importJSON(data)

        let reloaded = harness.makeStore()
        // 源会话 + 导入的会话都落在同一个 SQLite 库里
        XCTAssertEqual(reloaded.sessions.count, 2)
        XCTAssertEqual(Set(reloaded.sessions.map(\.title)), ["持久化"])
        XCTAssertTrue(
            reloaded.sessions.allSatisfy {
                reloaded.messages(for: $0.id).map(\.content) == ["x"]
            })
    }

    func testExportSingleSession() throws {
        let store = harness.makeStore()
        let a = store.createSession(title: "A")
        _ = store.createSession(title: "B")

        let data = try XCTUnwrap(try store.exportSessionJSON(id: a.id))
        let export = try JSONDecoder().decode(SessionExport.self, from: data)
        XCTAssertEqual(export.sessions.map(\.title), ["A"])
        XCTAssertNil(try store.exportSessionJSON(id: UUID()))
    }

    func testExportEmptyStoreRoundTrips() throws {
        let store = harness.makeStore()
        let data = try store.exportJSON()
        let result = try harness.makeStore().importJSON(data)
        XCTAssertEqual(result.importedSessions, 0)
        XCTAssertEqual(result.importedMessages, 0)
    }

    func testImportRejectsWrongFormat() {
        let store = harness.makeStore()
        let data = Data(
            #"{"format":"other-app","version":1,"app":"x","exportedAt":0,"sessions":[]}"#.utf8
        )
        XCTAssertThrowsError(try store.importJSON(data)) { error in
            guard case SessionImportError.unsupportedFormat = error else {
                return XCTFail("应为 unsupportedFormat，实际：\(error)")
            }
        }
    }

    func testImportRejectsUnsupportedVersion() throws {
        let store = harness.makeStore()
        var export = SessionExport(sessions: [])
        export.version = 99
        let data = try JSONEncoder().encode(export)

        XCTAssertThrowsError(try store.importJSON(data)) { error in
            guard case SessionImportError.unsupportedVersion(99) = error else {
                return XCTFail("应为 unsupportedVersion(99)，实际：\(error)")
            }
        }
    }

    func testImportRejectsMalformedJSON() {
        let store = harness.makeStore()
        XCTAssertThrowsError(try store.importJSON(Data("{broken".utf8))) { error in
            guard case SessionImportError.decodingFailed = error else {
                return XCTFail("应为 decodingFailed，实际：\(error)")
            }
        }
    }

    /// 坏数据（非法 role）应整体回滚，不能留下部分导入的会话。
    func testFailedImportRollsBackWithoutPartialData() {
        let store = harness.makeStore()
        _ = store.createSession(title: "已有")
        let invalid = """
            {"format":"deepseek-chat-sessions","version":1,"app":"DeepSeek Chat","exportedAt":0,"sessions":[{"id":"11111111-1111-1111-1111-111111111111","title":"坏会话","messages":[{"id":"22222222-2222-2222-2222-222222222222","role":"robot","content":"hi","isSearching":false,"isError":false,"createdAt":0}],"createdAt":0,"updatedAt":0}]}
            """

        XCTAssertThrowsError(try store.importJSON(Data(invalid.utf8)))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.title, "已有")
    }
}
