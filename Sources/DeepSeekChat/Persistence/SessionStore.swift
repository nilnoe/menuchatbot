import Combine
import Foundation
import GRDB

final class SessionStore: ObservableObject {
    /// 会话数据。setter 设为 private：所有 UI 通知改为显式
    /// `objectWillChange.send()`，流式写回（syncMessage）不会触发整树重算。
    private(set) var sessions: [ChatSession] = []

    private let directory: URL
    private let dbQueue: DatabaseQueue
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
        return migrator
    }

    // MARK: - 载入 / 旧数据迁移

    private func load() {
        do {
            let sessionRecords = try dbQueue.read { db in
                try SessionRecord.order(Column("createdAt").desc, Column("rowid").desc).fetchAll(db)
            }
            let messageRecords = try dbQueue.read { db in
                try MessageRecord.order(Column("position"), Column("rowid")).fetchAll(db)
            }
            let messagesBySession = Dictionary(grouping: messageRecords, by: \.sessionID)
            sessions = sessionRecords.map { record in
                ChatSession(
                    id: UUID(uuidString: record.id) ?? UUID(),
                    title: record.title,
                    messages: (messagesBySession[record.id] ?? []).map(\.chatMessage),
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
            }
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

    func createSession(title: String = "新对话") -> ChatSession {
        let now = Date()
        let session = ChatSession(
            id: UUID(),
            title: title,
            messages: [],
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(session, at: 0)
        do {
            try dbQueue.write { db in
                var record = SessionRecord(
                    id: session.id.uuidString,
                    title: title,
                    createdAt: now,
                    updatedAt: now
                )
                try record.insert(db)
            }
        } catch {
            AppLog.storage.error("创建会话写库失败: \(error, privacy: .public)")
        }
        objectWillChange.send()
        return session
    }

    func deleteSession(id: UUID) {
        if let session = session(id: id) {
            for message in session.messages {
                messageStates.removeValue(forKey: message.id)
            }
        }
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
        guard
            let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                $0.id == messageID
            })
        else { return }

        sessions[sessionIndex].messages.remove(at: messageIndex)
        sessions[sessionIndex].updatedAt = Date()
        messageStates.removeValue(forKey: messageID)

        do {
            try dbQueue.write { db in
                try MessageRecord.deleteOne(db, key: messageID.uuidString)
                for (position, message) in sessions[sessionIndex].messages.enumerated() {
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

    func session(id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    func history(for id: UUID) -> [APIMessage] {
        guard let session = session(id: id) else { return [] }
        return session.messages
            .filter { !$0.content.isEmpty }
            .map { APIMessage(role: $0.role.rawValue, content: $0.content) }
    }

    // MARK: - 导入 / 导出

    /// 导出全部会话为 JSON 备份数据。
    func exportJSON() throws -> Data {
        let export = SessionExport(sessions: sessions)
        return try JSONEncoder().encode(export)
    }

    /// 导出单个会话为 JSON 备份数据。
    func exportSessionJSON(id: UUID) throws -> Data? {
        guard let session = session(id: id) else { return nil }
        let export = SessionExport(sessions: [session])
        return try JSONEncoder().encode(export)
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
                        isSearching: false,
                        isError: false,
                        createdAt: message.createdAt
                    )
                },
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
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
            sessions.insert(session, at: 0)
        }
        objectWillChange.send()

        return SessionImportResult(
            importedSessions: imported.count,
            importedMessages: imported.reduce(0) { $0 + $1.messages.count }
        )
    }

    func appendMessage(sessionID: UUID, _ message: ChatMessage) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = Date()
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
        guard
            let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                $0.id == messageID
            })
        else { return }
        mutate(&sessions[sessionIndex].messages[messageIndex])
        sessions[sessionIndex].updatedAt = Date()
        persistMessage(
            sessions[sessionIndex].messages[messageIndex],
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
        guard
            let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                $0.id == state.id
            })
        else { return }
        sessions[sessionIndex].messages[messageIndex].content = state.content
        sessions[sessionIndex].messages[messageIndex].reasoning = state.reasoning
        sessions[sessionIndex].messages[messageIndex].sources = state.sources
        sessions[sessionIndex].messages[messageIndex].isSearching = state.isSearching
        sessions[sessionIndex].messages[messageIndex].isError = state.isError
        sessions[sessionIndex].updatedAt = Date()
        persistMessage(
            sessions[sessionIndex].messages[messageIndex],
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
            isSearching: message.isSearching,
            isError: message.isError,
            createdAt: message.createdAt,
            position: position
        )
    }

    /// 把整个会话（含全部消息）写入数据库，供迁移与导入复用。
    private func insertSession(_ session: ChatSession, into db: Database) throws {
        var sessionRecord = SessionRecord(
            id: session.id.uuidString,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt
        )
        try sessionRecord.insert(db)
        for (position, message) in session.messages.enumerated() {
            var messageRecord = makeMessageRecord(
                message, sessionID: session.id, position: position)
            try messageRecord.insert(db)
        }
    }
}

// MARK: - MessageSynchronizing（流式写回契约）

extension SessionStore: SessionStoring {}
