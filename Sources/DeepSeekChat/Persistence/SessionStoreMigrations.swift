import GRDB

extension SessionStore {
    // MARK: - Schema

    /// 数据库迁移链（v1~v4）。独立成文件控制 SessionStore.swift 规模。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionID", .text).notNull().references("session", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("reasoning", .text)
                t.column("sourcesJSON", .text)
                t.column("usageJSON", .text)
                t.column("isSearching", .boolean).notNull()
                t.column("isError", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(indexOn: "message", columns: ["sessionID", "position"])
        }
        // v2：message 表补充 usageJSON 列（旧库升级；新库 v1 建表已含）。
        migrator.registerMigration("v2") { db in
            if try !db.columns(in: "message").contains(where: { $0.name == "usageJSON" }) {
                try db.alter(table: "message") { t in
                    t.add(column: "usageJSON", .text)
                }
            }
        }
        // v3：session 表补充 isPinned 列（置顶分组）。
        migrator.registerMigration("v3") { db in
            if try !db.columns(in: "session").contains(where: { $0.name == "isPinned" }) {
                try db.alter(table: "session") { t in
                    t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
                }
            }
        }
        // v4：message 表补充派生列 tokenTotal / contentHash / indexVersion
        // （供侧栏聚合与索引幂等；旧库升级时按 usageJSON 回填 tokenTotal）。
        migrator.registerMigration("v4") { db in
            let messageColumns = try db.columns(in: "message").map(\.name)
            if !messageColumns.contains("tokenTotal") {
                try db.alter(table: "message") { t in
                    t.add(column: "tokenTotal", .integer).notNull().defaults(to: 0)
                }
                try db.execute(
                    sql:
                        """
                        UPDATE message
                        SET tokenTotal = COALESCE(
                            CAST(json_extract(usageJSON, '$.totalTokens') AS INTEGER), 0
                        )
                        WHERE usageJSON IS NOT NULL
                        """
                )
            }
            if !messageColumns.contains("contentHash") {
                try db.alter(table: "message") { t in
                    t.add(column: "contentHash", .text).notNull().defaults(to: "")
                }
            }
            if !messageColumns.contains("indexVersion") {
                try db.alter(table: "message") { t in
                    t.add(column: "indexVersion", .integer).notNull().defaults(to: 0)
                }
            }
        }
        // v5：message 表补充工具调用列（toolCallsJSON / toolCallID / toolName），
        // 工具调用循环的透明展示与历史回传（T2-3）。
        migrator.registerMigration("v5") { db in
            let messageColumns = try db.columns(in: "message").map(\.name)
            if !messageColumns.contains("toolCallsJSON") {
                try db.alter(table: "message") { t in
                    t.add(column: "toolCallsJSON", .text)
                }
            }
            if !messageColumns.contains("toolCallID") {
                try db.alter(table: "message") { t in
                    t.add(column: "toolCallID", .text)
                }
            }
            if !messageColumns.contains("toolName") {
                try db.alter(table: "message") { t in
                    t.add(column: "toolName", .text)
                }
            }
        }
        return migrator
    }
}
