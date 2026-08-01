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
    /// 消息状态 LRU 顺序（Tier 1-4）：超出上限逐出最久未用的状态，
    /// 避免长期使用内存准泄漏。当前会话 / 流式消息因渲染频繁而保持新鲜。
    private var messageStateOrder: [UUID] = []
    private static let messageStateLimit = 200

    /// 测试钩子：当前驻留的消息状态数（ACCEPTANCE T1-4a）。
    var messageStateCount: Int { messageStates.count }

    /// 索引事件流（Tier 1 第二批）：IndexCoordinator 订阅，事件即契约。
    let indexEvents: AsyncStream<IndexEvent>
    private var indexEventContinuation: AsyncStream<IndexEvent>.Continuation?

    init(storageDirectory: URL? = nil) {
        var continuation: AsyncStream<IndexEvent>.Continuation?
        indexEvents = AsyncStream { continuation = $0 }
        indexEventContinuation = continuation

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
                messageStateOrder.removeAll { $0 == message.id }
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
            publish(.sessionDeleted(id))
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
        messageStateOrder.removeAll { $0 == messageID }

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
            publish(.messageDeleted(sessionID: sessionID, messageID: messageID))
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
            // 纯工具调用消息可能没有正文，但必须回传（否则 API 拒绝后续 tool 消息）。
            .filter { !$0.content.isEmpty || !($0.toolCalls?.isEmpty ?? true) }
            .map { message in
                APIMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    toolCalls: message.toolCalls?.map { call in
                        APIToolCall(
                            id: call.id,
                            function: APIFunctionCall(
                                name: call.name,
                                arguments: call.arguments
                            )
                        )
                    },
                    toolCallID: message.toolCallID,
                    name: message.toolName
                )
            }
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
            let sessionRecords =
                try SessionRecord
                .order(Column("createdAt").desc, Column("rowid").desc)
                .fetchAll(db)
            let messageRecords =
                try MessageRecord
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
            let messages =
                try MessageRecord
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
        for session in imported {
            for (position, message) in session.messages.enumerated() {
                publish(
                    .messageUpserted(
                        sessionID: session.id,
                        messageID: message.id,
                        position: position,
                        contentHash: contentHash(of: message)
                    )
                )
            }
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
        var position = 0
        do {
            try dbQueue.write { db in
                position =
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
            publish(
                .messageUpserted(
                    sessionID: sessionID,
                    messageID: message.id,
                    position: position,
                    contentHash: contentHash(of: message)
                )
            )
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
        publish(
            .messageUpserted(
                sessionID: sessionID,
                messageID: messageID,
                position: messageIndex,
                contentHash: contentHash(of: messages[messageIndex])
            )
        )
        objectWillChange.send()
    }

    /// 取（或按需创建）一条消息的可观察状态。同一条消息始终返回同一实例。
    func messageState(for message: ChatMessage) -> MessageState {
        if let state = messageStates[message.id] {
            touchMessageState(message.id)
            return state
        }
        let state = MessageState(message: message)
        messageStates[message.id] = state
        touchMessageState(message.id)
        evictMessageStatesIfNeeded()
        return state
    }

    private func touchMessageState(_ id: UUID) {
        messageStateOrder.removeAll { $0 == id }
        messageStateOrder.append(id)
    }

    private func evictMessageStatesIfNeeded() {
        while messageStates.count > Self.messageStateLimit, !messageStateOrder.isEmpty {
            let evicted = messageStateOrder.removeFirst()
            messageStates.removeValue(forKey: evicted)
        }
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
        // 流式中间写回：只写消息行、不 touch 会话 updatedAt（写放大减半；
        // 会话时间戳在 commitMessage 时统一落库，行为对外不变）。
        persistMessage(
            messages[messageIndex],
            sessionID: sessionID,
            position: messageIndex,
            updatedAt: sessions[sessionIndex].updatedAt,
            touch: false
        )
    }

    /// 流式结束 / 停止时调用：把最终内容写回存储，并发布一次（刷新会话元数据）。
    func commitMessage(_ state: MessageState, sessionID: UUID) {
        syncMessage(state, sessionID: sessionID)
        if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
            let updatedAt = sessions[sessionIndex].updatedAt
            do {
                try dbQueue.write { db in
                    try touchSession(db, sessionID: sessionID, updatedAt: updatedAt)
                }
                let messages = messages(for: sessionID)
                if let messageIndex = messages.firstIndex(where: { $0.id == state.id }) {
                    publish(
                        .messageUpserted(
                            sessionID: sessionID,
                            messageID: state.id,
                            position: messageIndex,
                            contentHash: contentHash(of: messages[messageIndex])
                        )
                    )
                }
            } catch {
                AppLog.storage.error("提交会话时间戳写库失败: \(error, privacy: .public)")
            }
        }
        objectWillChange.send()
    }

    // MARK: - SQLite 写入辅助

    /// 单行写入：更新一条消息 + 会话 updatedAt，无需整库序列化。
    private func persistMessage(
        _ message: ChatMessage, sessionID: UUID, position: Int, updatedAt: Date,
        touch: Bool = true
    ) {
        do {
            try dbQueue.write { db in
                var record = makeMessageRecord(message, sessionID: sessionID, position: position)
                try record.upsert(db)
                if touch {
                    try touchSession(db, sessionID: sessionID, updatedAt: updatedAt)
                }
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
            toolCallsJSON: message.toolCalls.flatMap { calls in
                (try? JSONEncoder().encode(calls)).flatMap { String(data: $0, encoding: .utf8) }
            },
            toolCallID: message.toolCallID,
            toolName: message.toolName,
            isSearching: message.isSearching,
            isError: message.isError,
            createdAt: message.createdAt,
            position: position,
            tokenTotal: message.usage?.totalTokens ?? 0,
            contentHash: contentHash(of: message),
            indexVersion: 0
        )
    }

    /// 内容指纹（与索引事件 / 幂等共用同一公式）。
    private func contentHash(of message: ChatMessage) -> String {
        ContentHash.fnv1a(
            message.reasoning.map { message.content + "\u{0}" + $0 } ?? message.content)
    }

    private func publish(_ event: IndexEvent) {
        indexEventContinuation?.yield(event)
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

extension SessionStore: IndexEventPublishing {}
