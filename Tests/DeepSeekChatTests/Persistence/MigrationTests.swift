import GRDB
import XCTest

@testable import DeepSeekChat

final class MigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeState(_ json: [String: Any]) throws -> URL {
        let url = tempDir.appendingPathComponent("state.json")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return url
    }

    func testMigrateFullRecord() throws {
        let userID = UUID().uuidString
        let assistantID = UUID().uuidString
        let sessionID = UUID().uuidString
        let json: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": sessionID,
                    "title": "你好",
                    "createdAt": 1_700_000_000_000.0,
                    "updatedAt": 1_700_000_100_000.0,
                    "messages": [
                        [
                            "id": userID,
                            "role": "user",
                            "content": "hi",
                            "createdAt": 1_700_000_000_000.0,
                        ],
                        [
                            "id": assistantID,
                            "role": "assistant",
                            "content": "hello",
                            "reasoning": "think",
                            "sources": [
                                ["title": "A", "url": "https://a.com"],
                                ["title": "B", "url": ""],
                            ],
                            "error": true,
                            "searching": true,
                            "createdAt": 1_700_000_050_000.0,
                        ],
                    ],
                ]
            ]
        ]

        let sessions = try XCTUnwrap(
            Migration.migrateSessions(from: writeState(json))
        )
        XCTAssertEqual(sessions.count, 1)

        let session = sessions[0]
        XCTAssertEqual(session.id.uuidString, sessionID)
        XCTAssertEqual(session.title, "你好")
        XCTAssertEqual(session.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(session.messages.count, 2)

        let user = session.messages[0]
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.content, "hi")
        XCTAssertFalse(user.isError)
        XCTAssertFalse(user.isSearching)

        let assistant = session.messages[1]
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.reasoning, "think")
        XCTAssertTrue(assistant.isError)
        XCTAssertFalse(assistant.isSearching)
        // 空 URL 的来源被过滤
        XCTAssertEqual(assistant.sources?.map(\.url), ["https://a.com"])
    }

    func testMigrateMissingOptionalFields() throws {
        let json: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": UUID().uuidString,
                    "title": "空",
                    "createdAt": 1_000.0,
                    "updatedAt": 1_000.0,
                    "messages": [
                        [
                            "id": UUID().uuidString,
                            "role": "user",
                            "content": "x",
                            "createdAt": 1_000.0,
                        ]
                    ],
                ]
            ]
        ]

        let sessions = try XCTUnwrap(
            Migration.migrateSessions(from: writeState(json))
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions[0].messages[0].reasoning)
        XCTAssertNil(sessions[0].messages[0].sources)
        XCTAssertFalse(sessions[0].messages[0].isError)
    }

    func testMigrateInvalidUUIDsFallBack() throws {
        let json: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": "not-a-uuid",
                    "title": "x",
                    "createdAt": 1_000.0,
                    "updatedAt": 1_000.0,
                    "messages": [
                        [
                            "id": "also-bad",
                            "role": "user",
                            "content": "x",
                            "createdAt": 1_000.0,
                        ]
                    ],
                ]
            ]
        ]

        let sessions = try XCTUnwrap(
            Migration.migrateSessions(from: writeState(json))
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(sessions[0].id as UUID?)
        XCTAssertNotNil(sessions[0].messages[0].id as UUID?)
    }

    func testMigrateUnknownRoleBecomesAssistant() throws {
        let json: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": UUID().uuidString,
                    "title": "x",
                    "createdAt": 1_000.0,
                    "updatedAt": 1_000.0,
                    "messages": [
                        [
                            "id": UUID().uuidString,
                            "role": "system",
                            "content": "x",
                            "createdAt": 1_000.0,
                        ]
                    ],
                ]
            ]
        ]

        let sessions = try XCTUnwrap(
            Migration.migrateSessions(from: writeState(json))
        )
        XCTAssertEqual(sessions[0].messages[0].role, .assistant)
    }

    func testMigrateEmptyMessages() throws {
        let json: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": UUID().uuidString,
                    "title": "x",
                    "createdAt": 1_000.0,
                    "updatedAt": 1_000.0,
                    "messages": [],
                ]
            ]
        ]

        let sessions = try XCTUnwrap(
            Migration.migrateSessions(from: writeState(json))
        )
        XCTAssertTrue(sessions[0].messages.isEmpty)
    }

    func testMigrateMultipleSessionsPreservesOrder() throws {
        let json: [String: Any] = [
            "deepseek-chat.sessions.v1": [
                [
                    "id": UUID().uuidString, "title": "一", "createdAt": 1.0, "updatedAt": 1.0,
                    "messages": [],
                ],
                [
                    "id": UUID().uuidString, "title": "二", "createdAt": 2.0, "updatedAt": 2.0,
                    "messages": [],
                ],
            ]
        ]

        let sessions = try XCTUnwrap(
            Migration.migrateSessions(from: writeState(json))
        )
        XCTAssertEqual(sessions.map(\.title), ["一", "二"])
    }

    func testMigrateMissingFileReturnsNil() {
        let missing = tempDir.appendingPathComponent("nope.json")
        XCTAssertNil(Migration.migrateSessions(from: missing))
    }

    func testMigrateInvalidJSONReturnsNil() throws {
        let url = tempDir.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(Migration.migrateSessions(from: url))
    }

    func testMigrateMissingSessionsKeyReturnsNil() throws {
        let json: [String: Any] = ["other-key": [1, 2, 3]]
        XCTAssertNil(Migration.migrateSessions(from: try writeState(json)))
    }

    func testMigrateWrongSessionsTypeReturnsNil() throws {
        let json: [String: Any] = ["deepseek-chat.sessions.v1": "not-an-array"]
        XCTAssertNil(Migration.migrateSessions(from: try writeState(json)))
    }

    // MARK: - v4 派生列迁移（Tier 1-2，ACCEPTANCE T1-2a）

    /// 旧库升级：v3 schema（含 usageJSON）→ v4 补齐派生列并按 usageJSON 回填 tokenTotal。
    func testLegacyDatabaseWithoutDerivedColumnsUpgrades() throws {
        let dbURL = tempDir.appendingPathComponent("sessions.sqlite")
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
        legacy.registerMigration("v2") { db in
            try db.alter(table: "message") { t in
                t.add(column: "usageJSON", .text)
            }
        }
        legacy.registerMigration("v3") { db in
            try db.alter(table: "session") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }
        let queue = try DatabaseQueue(path: dbURL.path)
        try legacy.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql:
                    """
                    INSERT INTO session (id, title, createdAt, updatedAt, isPinned)
                    VALUES ('s1', '旧会话', '2026-01-01', '2026-01-02', 0)
                    """
            )
            try db.execute(
                sql:
                    """
                    INSERT INTO message
                    (id, sessionID, role, content, reasoning, sourcesJSON, usageJSON,
                     isSearching, isError, createdAt, position)
                    VALUES
                    ('m1', 's1', 'assistant', '旧回答', NULL, NULL,
                     '{"promptTokens":30,"cachedTokens":12,"completionTokens":8,"totalTokens":38}',
                     0, 0, '2026-01-02', 0)
                    """
            )
        }

        // SessionStore 启动时跑 v1→v4 全量迁移（v1~v3 已记录，实际只补 v4）。
        _ = SessionStore(storageDirectory: tempDir)

        let after = try DatabaseQueue(path: dbURL.path)
        let derived = try after.read { db -> (Int, String, Int) in
            (
                try Int.fetchOne(db, sql: "SELECT tokenTotal FROM message") ?? -1,
                try String.fetchOne(db, sql: "SELECT contentHash FROM message") ?? "",
                try Int.fetchOne(db, sql: "SELECT indexVersion FROM message") ?? -1
            )
        }
        XCTAssertEqual(derived.0, 38)
        XCTAssertEqual(derived.1, "")
        XCTAssertEqual(derived.2, 0)
    }
}
