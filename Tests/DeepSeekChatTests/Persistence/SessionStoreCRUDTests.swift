import GRDB
import XCTest

@testable import DeepSeekChat

/// 会话生命周期：创建 / 重命名 / 删除 / 置顶、Token 用量持久化、旧库 schema 升级。
final class SessionStoreCRUDTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    // MARK: - 基础操作

    func testCreateSessionInsertsAtFront() {
        let store = harness.makeStore()
        let first = store.createSession(title: "A")
        let second = store.createSession(title: "B")
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions[0].id, second.id)
        XCTAssertEqual(store.sessions[1].id, first.id)
        XCTAssertTrue(store.messages(for: second.id).isEmpty)
    }

    func testCreateSessionDefaultsTitle() {
        let store = harness.makeStore()
        let session = store.createSession()
        XCTAssertEqual(session.title, "新对话")
    }

    // MARK: - Token 用量持久化

    func testUsagePersistsAcrossReload() {
        let store = harness.makeStore()
        let session = store.createSession(title: "用量会话")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "hi"))
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "answer",
                usage: TokenUsage(
                    promptTokens: 30, cachedTokens: 12, completionTokens: 8, totalTokens: 38)
            )
        )

        let reloaded = harness.makeStore()
        let last = reloaded.session(id: session.id)?.messages.last
        XCTAssertEqual(
            last?.usage,
            TokenUsage(promptTokens: 30, cachedTokens: 12, completionTokens: 8, totalTokens: 38)
        )
    }

    func testMessagesWithoutUsageStayNil() {
        let store = harness.makeStore()
        let session = store.createSession(title: "无用量")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "hi"))
        store.appendMessage(sessionID: session.id, ChatMessage(role: .assistant, content: "ok"))

        let reloaded = harness.makeStore()
        XCTAssertNil(reloaded.session(id: session.id)?.messages.last?.usage)
    }

    // MARK: - 派生列（Tier 1-2，ACCEPTANCE T1-2a / T1-2c）

    func testTokenTotalAndContentHashPersist() throws {
        let store = harness.makeStore()
        let session = store.createSession(title: "派生列")
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "内容",
                usage: TokenUsage(
                    promptTokens: 30, cachedTokens: 12, completionTokens: 8, totalTokens: 38)
            )
        )

        // 直接查库断言派生列（消息 API 暂不暴露 tokenTotal）。
        let queue = try DatabaseQueue(
            path: harness.tempDir.appendingPathComponent("sessions.sqlite").path)
        let derived = try queue.read { db -> (Int, String, Int) in
            (
                try Int.fetchOne(db, sql: "SELECT tokenTotal FROM message") ?? -1,
                try String.fetchOne(db, sql: "SELECT contentHash FROM message") ?? "",
                try Int.fetchOne(db, sql: "SELECT indexVersion FROM message") ?? -1
            )
        }
        XCTAssertEqual(derived.0, 38)
        XCTAssertEqual(derived.1, ContentHash.fnv1a("内容"))
        XCTAssertEqual(derived.2, 0)
    }

    // MARK: - 置顶

    func testSetPinnedPersistsAcrossReload() {
        let store = harness.makeStore()
        let session = store.createSession(title: "置顶会话")
        store.setPinned(id: session.id, pinned: true)

        let reloaded = harness.makeStore()
        XCTAssertTrue(reloaded.session(id: session.id)?.isPinned ?? false)

        // 取消置顶后跨实例保持未置顶
        reloaded.setPinned(id: session.id, pinned: false)
        let final = harness.makeStore()
        XCTAssertFalse(final.session(id: session.id)?.isPinned ?? true)
    }

    func testSetPinnedDoesNotTouchUpdatedAt() {
        let store = harness.makeStore()
        let session = store.createSession(title: "置顶时间")
        let before = store.session(id: session.id)?.updatedAt
        store.setPinned(id: session.id, pinned: true)
        XCTAssertEqual(store.session(id: session.id)?.updatedAt, before)
    }

    func testLegacyDatabaseWithoutPinnedColumnUpgrades() throws {
        // 旧版 schema：session 表无 isPinned、message 表无 usageJSON。
        let dbURL = harness.tempDir.appendingPathComponent("sessions.sqlite")
        var legacy = DatabaseMigrator()
        legacy.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionID", .text).notNull().references("session", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("reasoning", .text)
                t.column("sourcesJSON", .text)
                t.column("isSearching", .boolean).notNull()
                t.column("isError", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(indexOn: "message", columns: ["sessionID", "position"])
        }
        let queue = try DatabaseQueue(path: dbURL.path)
        try legacy.migrate(queue)

        let store = harness.makeStore()
        let session = store.createSession(title: "旧库升级")
        store.setPinned(id: session.id, pinned: true)

        let reloaded = harness.makeStore()
        XCTAssertTrue(reloaded.session(id: session.id)?.isPinned ?? false)
    }

    func testLegacyDatabaseWithoutUsageColumnUpgrades() throws {
        // 用旧版 v1 schema（无 usageJSON 列）预建库，再让 SessionStore 跑迁移。
        let dbURL = harness.tempDir.appendingPathComponent("sessions.sqlite")
        var legacy = DatabaseMigrator()
        legacy.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionID", .text).notNull().references("session", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("reasoning", .text)
                t.column("sourcesJSON", .text)
                t.column("isSearching", .boolean).notNull()
                t.column("isError", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(indexOn: "message", columns: ["sessionID", "position"])
        }
        let queue = try DatabaseQueue(path: dbURL.path)
        try legacy.migrate(queue)

        // 旧库升级后应可写用量并跨实例读回。
        let store = harness.makeStore()
        let session = store.createSession(title: "升级库")
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(
                role: .assistant,
                content: "migrated",
                usage: TokenUsage(
                    promptTokens: 5, cachedTokens: 0, completionTokens: 5, totalTokens: 10)
            )
        )
        let reloaded = harness.makeStore()
        XCTAssertEqual(reloaded.session(id: session.id)?.messages.last?.usage?.totalTokens, 10)
    }

    func testRenameSession() {
        let store = harness.makeStore()
        let session = store.createSession(title: "旧")
        store.renameSession(id: session.id, title: "新标题")
        XCTAssertEqual(store.session(id: session.id)?.title, "新标题")
    }

    func testRenameUnknownIDNoop() {
        let store = harness.makeStore()
        store.renameSession(id: UUID(), title: "x")
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testDeleteSession() {
        let store = harness.makeStore()
        let a = store.createSession()
        let b = store.createSession()
        store.deleteSession(id: a.id)
        XCTAssertEqual(store.sessions.map(\.id), [b.id])
    }

    func testDeleteUnknownIDNoop() {
        let store = harness.makeStore()
        _ = store.createSession()
        store.deleteSession(id: UUID())
        XCTAssertEqual(store.sessions.count, 1)
    }
}
