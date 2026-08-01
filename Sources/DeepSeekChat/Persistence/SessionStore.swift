import Combine
import Foundation
import GRDB

final class SessionStore: ObservableObject {
    /// 会话列表（仅元数据）。setter 设为 private：所有 UI 通知改为显式
    /// `objectWillChange.send()`，流式写回（syncMessage）不会触发整树重算。
    private(set) var sessions: [SessionSummary] = []

    private let directory: URL
    private let dbQueue: DatabaseQueue
    /// 惰性消息缓存：仅已打开过的会话持有消息正文，上限 LRU 淘汰
    /// （Tier 1-1，消除启动全量物化）。
    private var messageCache: [UUID: [ChatMessage]] = [:]
    private var messageCacheOrder: [UUID] = []
    private static let messageCacheLimit = 3
    /// 消息 ID -> 消息状态。同一消息始终复用同一个状态对象，
    /// 保证流式更新只刷新该消息所在的视图。
    private var messageStates: [UUID: MessageState] = [:]

    init(storageDirectory: URL? = nil) {
        let dir = storageDirectory ?? SessionStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir

        let dbURL = dir.appendingPathComponent("sessions.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        } catch {
            // 数据库打不开时退回内存库，保证应用可用（数据不落盘）。
            AppLog.storage.error("打开会话数据库失败，改用内存库: \(error, privacy: .public)")
            dbQueue = try! DatabaseQueue(configuration: configuration)
        }
        do {
            try Self.migrator.migrate(dbQueue)
        } catch {
            AppLog.storage.error("初始化数据库表失败: \(error, privacy: .public)")
        }
        migrateLegacyDataIfNeeded()
        load()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent(
            AppConfiguration.appSupportDirectoryName, isDirectory: true)
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
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
        return migrator
    }

    // MARK: - 载入 / 旧数据迁移

    /// 会话列表聚合查询：条数 / token 合计 / 最后消息来源全部由 SQL 计算，
    /// 不物化任何消息正文。
    private static let summarySQL =
        """
        SELECT session.id, session.title, session.createdAt, session.updatedAt, session.isPinned,
               COUNT(message.id) AS messageCount,
               COALESCE(SUM(message.tokenTotal), 0) AS totalTokens,
               (SELECT sourcesJSON FROM message
                WHERE message.sessionID = session.id
                ORDER BY position DESC, rowid DESC LIMIT 1) AS lastSourcesJSON
        FROM session
        LEFT JOIN message ON message.sessionID = session.id
        GROUP BY session.id
        ORDER BY session.createdAt DESC, session.rowid DESC
        """

    private struct SessionSummaryRecord: Decodable, FetchableRecord {
        var id: String
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var isPinned: Bool
        var messageCount: Int
        var totalTokens: Int
        var lastSourcesJSON: String?

        var summary: SessionSummary {
            let sources = lastSourcesJSON.flatMap {
                try? JSONDecoder().decode([Source].self, from: Data($0.utf8))
            }
            return SessionSummary(
                id: UUID(uuidString: id) ?? UUID(),
                title: title,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isPinned: isPinned,
                messageCount: messageCount,
                totalTokens: totalTokens,
                lastMessageHasSources: !(sources?.isEmpty ?? true)
            )
        }
    }

    private func load() {
        messageCache.removeAll()
        messageCacheOrder.removeAll()
        do {
            let records = try dbQueue.read { db in
                try SessionSummaryRecord.fetchAll(db, sql: Self.summarySQL)
            }
            sessions = records.map(\.summary)
        } catch {
            AppLog.storage.error("读取会话失败: \(error, privacy: .public)")
        }
    }

    /// 把旧版 sessions.json / state.json 一次性迁入 SQLite（仅当数据库为空时执行）。
    private func migrateLegacyDataIfNeeded() {
        do {
            let count = try dbQueue.read { db in try SessionRecord.fetchCount(db) }
            guard count == 0 else { return }

            let jsonURL = directory.appendingPathComponent("sessions.json")
            let legacySessions: [ChatSession]?
            if let data = try? Data(contentsOf: jsonURL),
                let decoded = try? JSONDecoder().decode([ChatSession].self, from: data)
            {
                legacySessions = decoded
            } else if let migrated = Migration.migrateSessions(
                from: directory.appendingPathComponent("state.json"))
            {
                legacySessions = migrated
            } else {
                legacySessions = nil
            }

            guard let legacySessions else { return }
            try dbQueue.write { db in
                for session in legacySessions {
                    try insertSession(session, into: db)
                }
            }
        } catch {
            AppLog.storage.error("迁移旧会话数据失败: \(error, privacy: .public)")
        }
    }

    // MARK: - 会话操作

    @discardableResult
    func createSession(title: String = "新对话") -> SessionSummary {
        let now = Date()
        let session = ChatSession(
            id: UUID(),
            title: title,
            messages: [],
            createdAt: now,
            updatedAt: now,
            isPinned: false
        )
        let summary = makeSummary(from: session)
        sessions.insert(summary, at: 0)
        do {
            try dbQueue.write { db in
                var record = SessionRecord(
                    id: session.id.uuidString,
                    title: title,
                    createdAt: now,
                    updatedAt: now,
                    isPinned: session.isPinned
                )
                try record.insert(db)
            }
        } catch {
            AppLog.storage.error("创建会话写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
        return summary
    }

    func deleteSession(id: UUID) {
        if let session = session(id: id) {
            for message in session.messages {
                messageStates.removeValue(forKey: message.id)
            }
        }
        messageCache.removeValue(forKey: id)
        messageCacheOrder.removeAll { $0 == id }
        sessions.removeAll { $0.id == id }
        do {
            try dbQueue.write { db in
                try MessageRecord
                    .filter(Column("sessionID") == id.uuidString)
                    .deleteAll(db)
                try SessionRecord.deleteOne(db, key: id.uuidString)
            }
        } catch {
            AppLog.storage.error("删除会话写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
    }

    /// 删除单条消息（重试场景：清掉末尾的错误回复后重新生成）。
    /// 删除后重排剩余消息的 position，保持数据库顺序连续。
    func removeMessage(sessionID: UUID, messageID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var updated = messages(for: sessionID)
        guard let messageIndex = updated.firstIndex(where: { $0.id == messageID }) else { return }

        updated.remove(at: messageIndex)
        messageCache[sessionID] = updated
        sessions[sessionIndex].messageCount = updated.count
        sessions[sessionIndex].totalTokens = updated.reduce(0) {
            $0 + ($1.usage?.totalTokens ?? 0)
        }
        sessions[sessionIndex].lastMessageHasSources = !(updated.last?.sources?.isEmpty ?? true)
        sessions[sessionIndex].updatedAt = Date()
        messageStates.removeValue(forKey: messageID)

        do {
            try dbQueue.write { db in
                try MessageRecord.deleteOne(db, key: messageID.uuidString)
                for (position, message) in updated.enumerated() {
                    var record = makeMessageRecord(
                        message,
                        sessionID: sessionID,
                        position: position
                    )
                    try record.upsert(db)
                }
                try touchSession(
                    db, sessionID: sessionID, updatedAt: sessions[sessionIndex].updatedAt)
            }
        } catch {
            AppLog.storage.error("删除消息写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
    }

    func renameSession(id: UUID, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = title
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE session SET title = ? WHERE id = ?",
                    arguments: [title, id.uuidString]
                )
            }
        } catch {
            AppLog.storage.error("重命名会话写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
    }

    func summary(id: UUID) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    /// 物化完整会话：元数据来自 summaries，消息按需加载。
    func session(id: UUID) -> ChatSession? {
        guard let summary = summary(id: id) else { return nil }
        return ChatSession(
            id: id,
            title: summary.title,
            messages: messages(for: id),
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            isPinned: summary.isPinned
        )
    }

    /// 惰性加载 / 缓存指定会话的消息（LRU 上限，避免长会话常驻）。
    func messages(for id: UUID) -> [ChatMessage] {
        if let cached = messageCache[id] {
            touchCache(id)
            return cached
        }
        let records =
            (try? dbQueue.read { db in
                try MessageRecord
                    .filter(Column("sessionID") == id.uuidString)
                    .order(Column("position"), Column("rowid"))
                    .fetchAll(db)
            }) ?? []
        let messages = records.map(\.chatMessage)
        storeCache(messages, for: id)
        return messages
    }

    /// 取会话尾部（最新）`limit` 条消息，供聊天区首次渲染（分页，Tier 1-1e）。
    func messagesTail(for id: UUID, limit: Int) -> [ChatMessage] {
        let records =
            (try? dbQueue.read { db in
                try MessageRecord
                    .filter(Column("sessionID") == id.uuidString)
                    .order(Column("position").desc, Column("rowid").desc)
                    .limit(limit)
                    .fetchAll(db)
            }) ?? []
        return records.reversed().map(\.chatMessage)
    }

    /// 取比 `cursor` 更旧（position 更小）的 `limit` 条消息，供上翻增量加载。
    func messagesBefore(_ cursor: ChatMessage, sessionID: UUID, limit: Int) -> [ChatMessage] {
        guard
            let cursorPosition =
                (try? dbQueue.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT position FROM message WHERE id = ?",
                        arguments: [cursor.id.uuidString]
                    )
                })
        else { return [] }
        let records =
            (try? dbQueue.read { db in
                try MessageRecord
                    .filter(
                        Column("sessionID") == sessionID.uuidString
                            && Column("position") < cursorPosition
                    )
                    .order(Column("position").desc, Column("rowid").desc)
                    .limit(limit)
                    .fetchAll(db)
            }) ?? []
        return records.reversed().map(\.chatMessage)
    }

    private func touchCache(_ id: UUID) {
        messageCacheOrder.removeAll { $0 == id }
        messageCacheOrder.append(id)
    }

    private func storeCache(_ messages: [ChatMessage], for id: UUID) {
        messageCache[id] = messages
        touchCache(id)
        while messageCacheOrder.count > Self.messageCacheLimit {
            let evicted = messageCacheOrder.removeFirst()
            messageCache.removeValue(forKey: evicted)
        }
    }

    private func makeSummary(from session: ChatSession) -> SessionSummary {
        SessionSummary(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            isPinned: session.isPinned,
            messageCount: session.messages.count,
            totalTokens: session.messages.reduce(0) {
                $0 + ($1.usage?.totalTokens ?? 0)
            },
            lastMessageHasSources: !(session.messages.last?.sources?.isEmpty ?? true)
        )
    }

    func history(for id: UUID) -> [APIMessage] {
        messages(for: id)
            .filter { !$0.content.isEmpty }
            .map { APIMessage(role: $0.role.rawValue, content: $0.content) }
    }

    // MARK: - 导入 / 导出

    /// 导出全部会话为 JSON 备份数据。
    func exportJSON() throws -> Data {
        let export = SessionExport(sessions: try allSessionsFromDB())
        return try JSONEncoder().encode(export)
    }

    /// 导出单个会话为 JSON 备份数据。
    func exportSessionJSON(id: UUID) throws -> Data? {
        guard let session = try sessionFromDB(id: id) else { return nil }
        let export = SessionExport(sessions: [session])
        return try JSONEncoder().encode(export)
    }

    /// 导出直接读库（不依赖内存缓存），保证与持久化内容一致。
    private func allSessionsFromDB() throws -> [ChatSession] {
        try dbQueue.read { db in
            let sessionRecords = try SessionRecord
                .order(Column("createdAt").desc, Column("rowid").desc)
                .fetchAll(db)
            let messageRecords = try MessageRecord
                .order(Column("position"), Column("rowid"))
                .fetchAll(db)
            let messagesBySession = Dictionary(grouping: messageRecords, by: \.sessionID)
            return sessionRecords.map { record in
                ChatSession(
                    id: UUID(uuidString: record.id) ?? UUID(),
                    title: record.title,
                    messages: (messagesBySession[record.id] ?? []).map(\.chatMessage),
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    isPinned: record.isPinned
                )
            }
        }
    }

    private func sessionFromDB(id: UUID) throws -> ChatSession? {
        try dbQueue.read { db in
            guard let record = try SessionRecord.fetchOne(db, key: id.uuidString) else {
                return nil
            }
            let messages = try MessageRecord
                .filter(Column("sessionID") == id.uuidString)
                .order(Column("position"), Column("rowid"))
                .fetchAll(db)
                .map(\.chatMessage)
            return ChatSession(
                id: UUID(uuidString: record.id) ?? UUID(),
                title: record.title,
                messages: messages,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                isPinned: record.isPinned
            )
        }
    }

    /// 从 JSON 备份导入会话。
    ///
    /// 安全策略：导入的会话与消息一律重新生成 UUID，避免与现有数据冲突；
    /// 解码或校验失败则整体回滚，不写入任何部分数据。
    func importJSON(_ data: Data) throws -> SessionImportResult {
        let export: SessionExport
        do {
            export = try JSONDecoder().decode(SessionExport.self, from: data)
        } catch {
            throw SessionImportError.decodingFailed(error.localizedDescription)
        }
        guard export.format == SessionExport.formatID else {
            throw SessionImportError.unsupportedFormat
        }
        guard export.version == SessionExport.currentVersion else {
            throw SessionImportError.unsupportedVersion(export.version)
        }

        // 重新生成所有 UUID（会话与消息），保证不覆盖现有数据。
        let imported = export.sessions.map { session in
            ChatSession(
                id: UUID(),
                title: session.title,
                messages: session.messages.map { message in
                    ChatMessage(
                        id: UUID(),
                        role: message.role,
                        content: message.content,
                        reasoning: message.reasoning,
                        sources: message.sources,
                        usage: message.usage,
                        isSearching: false,
                        isError: false,
                        createdAt: message.createdAt
                    )
                },
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                isPinned: session.isPinned
            )
        }

        // 先全部写库成功后再改内存态；写库失败则抛错，不产生部分导入。
        try dbQueue.write { db in
            for session in imported {
                try insertSession(session, into: db)
            }
        }
        // 保持文件顺序：逆序逐个插到数组头部。
        for session in imported.reversed() {
            sessions.insert(makeSummary(from: session), at: 0)
        }
        objectWillChange.send()

        return SessionImportResult(
            importedSessions: imported.count,
            importedMessages: imported.reduce(0) { $0 + $1.messages.count }
        )
    }

    func appendMessage(sessionID: UUID, _ message: ChatMessage) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].updatedAt = Date()
        sessions[index].messageCount += 1
        sessions[index].totalTokens += message.usage?.totalTokens ?? 0
        sessions[index].lastMessageHasSources = !(message.sources?.isEmpty ?? true)
        if var cached = messageCache[sessionID] {
            cached.append(message)
            messageCache[sessionID] = cached
        }
        do {
            try dbQueue.write { db in
                let position =
                    try Int.fetchOne(
                        db,
                        sql:
                            "SELECT COALESCE(MAX(position), -1) + 1 FROM message WHERE sessionID = ?",
                        arguments: [sessionID.uuidString]
                    ) ?? 0
                var record = makeMessageRecord(message, sessionID: sessionID, position: position)
                try record.insert(db)
                try touchSession(db, sessionID: sessionID, updatedAt: sessions[index].updatedAt)
            }
        } catch {
            AppLog.storage.error("追加消息写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
    }

    func updateMessage(sessionID: UUID, messageID: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var messages = messages(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let oldTokens = messages[messageIndex].usage?.totalTokens ?? 0
        mutate(&messages[messageIndex])
        let newTokens = messages[messageIndex].usage?.totalTokens ?? 0
        messageCache[sessionID] = messages
        sessions[sessionIndex].totalTokens += newTokens - oldTokens
        sessions[sessionIndex].lastMessageHasSources = !(messages.last?.sources?.isEmpty ?? true)
        sessions[sessionIndex].updatedAt = Date()
        persistMessage(
            messages[messageIndex],
            sessionID: sessionID,
            position: messageIndex,
            updatedAt: sessions[sessionIndex].updatedAt
        )
        objectWillChange.send()
    }

    /// 取（或按需创建）一条消息的可观察状态。同一条消息始终返回同一实例。
    func messageState(for message: ChatMessage) -> MessageState {
        if let state = messageStates[message.id] {
            return state
        }
        let state = MessageState(message: message)
        messageStates[message.id] = state
        return state
    }

    /// 流式期间把最新内容写回存储，**不**触发 UI 通知，仅保证中途退出不丢已生成内容。
    func syncMessage(_ state: MessageState, sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var messages = messages(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == state.id }) else { return }
        let oldTokens = messages[messageIndex].usage?.totalTokens ?? 0
        messages[messageIndex].content = state.content
        messages[messageIndex].reasoning = state.reasoning
        messages[messageIndex].sources = state.sources
        messages[messageIndex].usage = state.usage
        messages[messageIndex].isSearching = state.isSearching
        messages[messageIndex].isError = state.isError
        messageCache[sessionID] = messages
        let newTokens = messages[messageIndex].usage?.totalTokens ?? 0
        sessions[sessionIndex].totalTokens += newTokens - oldTokens
        sessions[sessionIndex].lastMessageHasSources = !(messages.last?.sources?.isEmpty ?? true)
        sessions[sessionIndex].updatedAt = Date()
        persistMessage(
            messages[messageIndex],
            sessionID: sessionID,
            position: messageIndex,
            updatedAt: sessions[sessionIndex].updatedAt
        )
    }

    /// 流式结束 / 停止时调用：把最终内容写回存储，并发布一次（刷新会话元数据）。
    func commitMessage(_ state: MessageState, sessionID: UUID) {
        syncMessage(state, sessionID: sessionID)
        objectWillChange.send()
    }

    // MARK: - SQLite 写入辅助

    /// 单行写入：更新一条消息 + 会话 updatedAt，无需整库序列化。
    private func persistMessage(
        _ message: ChatMessage, sessionID: UUID, position: Int, updatedAt: Date
    ) {
        do {
            try dbQueue.write { db in
                var record = makeMessageRecord(message, sessionID: sessionID, position: position)
                try record.upsert(db)
                try touchSession(db, sessionID: sessionID, updatedAt: updatedAt)
            }
        } catch {
            AppLog.storage.error("更新消息写库失败: \(error, privacy: .public)")
        }
    }

    private func touchSession(_ db: Database, sessionID: UUID, updatedAt: Date) throws {
        try db.execute(
            sql: "UPDATE session SET updatedAt = ? WHERE id = ?",
            arguments: [updatedAt, sessionID.uuidString]
        )
    }

    private func makeMessageRecord(_ message: ChatMessage, sessionID: UUID, position: Int)
        -> MessageRecord
    {
        MessageRecord(
            id: message.id.uuidString,
            sessionID: sessionID.uuidString,
            role: message.role.rawValue,
            content: message.content,
            reasoning: message.reasoning,
            sourcesJSON: message.sources.flatMap { sources in
                (try? JSONEncoder().encode(sources)).flatMap { String(data: $0, encoding: .utf8) }
            },
            usageJSON: message.usage.flatMap { usage in
                (try? JSONEncoder().encode(usage)).flatMap { String(data: $0, encoding: .utf8) }
            },
            isSearching: message.isSearching,
            isError: message.isError,
            createdAt: message.createdAt,
            position: position,
            tokenTotal: message.usage?.totalTokens ?? 0,
            contentHash: ContentHash.fnv1a(
                message.reasoning.map { message.content + "\u{0}" + $0 } ?? message.content),
            indexVersion: 0
        )
    }

    /// 把整个会话（含全部消息）写入数据库，供迁移与导入复用。
    private func insertSession(_ session: ChatSession, into db: Database) throws {
        var sessionRecord = SessionRecord(
            id: session.id.uuidString,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            isPinned: session.isPinned
        )
        try sessionRecord.insert(db)
        for (position, message) in session.messages.enumerated() {
            var messageRecord = makeMessageRecord(
                message, sessionID: session.id, position: position)
            try messageRecord.insert(db)
        }
    }

    /// 置顶 / 取消置顶会话。置顶是轻量偏好，不改变 updatedAt（不影响时间分组）。
    func setPinned(id: UUID, pinned: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
            sessions[index].isPinned != pinned
        else { return }
        sessions[index].isPinned = pinned
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE session SET isPinned = ? WHERE id = ?",
                    arguments: [pinned, id.uuidString]
                )
            }
        } catch {
            AppLog.storage.error("置顶会话写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
    }
}

// MARK: - MessageSynchronizing（流式写回契约）

extension SessionStore: SessionStoring {}
