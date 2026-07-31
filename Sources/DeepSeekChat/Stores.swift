import Combine
import Foundation
import GRDB
import Security

/// 单条消息的可观察状态。
///
/// 流式回复期间每次 token 分片只更新当前消息的 `MessageState`，
/// 由对应消息行单独观察，避免触发整棵视图树（会话列表 / 全部消息）重算。
///
/// 文本累积采用「增量缓冲 + 定时聚合」：
/// 分片先追加进 `pendingContent`（不触发发布），由调用方按 30~60ms 窗口调用
/// `flushPending()` 一次性提交。否则每分片都会让 SwiftUI 对**全文**重新排版，
/// 单条长消息会退化成 O(n²)。
final class MessageState: ObservableObject, Identifiable {
    let id: UUID
    let role: Role

    @Published private(set) var content: String
    @Published private(set) var reasoning: String?
    @Published var sources: [Source]?
    @Published var isSearching: Bool
    @Published private(set) var isError: Bool
    /// 消息自身是否处于流式（由本对象维护，不依赖 ChatView 的可覆盖状态）。
    /// 即使外部流式状态被旧任务收尾误清，行内仍走节流的实时渲染路径。
    @Published private(set) var isStreaming = false

    /// 尚未聚合到 UI 的流式增量。
    private var pendingContent = ""
    private var pendingReasoning = ""

    init(message: ChatMessage) {
        self.id = message.id
        self.role = message.role
        self.content = message.content
        self.reasoning = message.reasoning
        self.sources = message.sources
        self.isSearching = message.isSearching
        self.isError = message.isError
    }

    var hasPendingChanges: Bool {
        !pendingContent.isEmpty || !pendingReasoning.isEmpty
    }

    /// 追加正文分片：只进缓冲，不发布。
    func appendContent(_ chunk: String) {
        pendingContent += chunk
        if !isStreaming { isStreaming = true }
    }

    /// 追加思考分片：只进缓冲，不发布。
    func appendReasoning(_ chunk: String) {
        pendingReasoning += chunk
        if !isStreaming { isStreaming = true }
    }

    /// 流式结束（完成 / 错误 / 取消）时调用，恢复非流式渲染。
    func markStreamEnded() {
        if isStreaming { isStreaming = false }
    }

    /// 把缓冲的增量一次性提交给 UI（触发一次 objectWillChange）。
    func flushPending() {
        if !pendingContent.isEmpty {
            content += pendingContent
            pendingContent = ""
        }
        if !pendingReasoning.isEmpty {
            reasoning = (reasoning ?? "") + pendingReasoning
            pendingReasoning = ""
        }
    }

    func setSearching(_ value: Bool) {
        isSearching = value
    }

    func setSources(_ sources: [Source]) {
        self.sources = sources
        isSearching = false
    }

    /// 出错时丢弃未提交的增量，直接替换为错误信息。
    func setError(_ message: String) {
        pendingContent = ""
        pendingReasoning = ""
        content = message
        isError = true
        isSearching = false
    }
}

// MARK: - SQLite 记录（GRDB Record）

/// `session` 表记录。
struct SessionRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "session"

    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

/// `message` 表记录。sources 以 JSON 文本存于单列，避免引入嵌套表。
struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "message"

    var id: String
    var sessionID: String
    var role: String
    var content: String
    var reasoning: String?
    var sourcesJSON: String?
    var isSearching: Bool
    var isError: Bool
    var createdAt: Date
    var position: Int

    var chatMessage: ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            role: role == "user" ? .user : .assistant,
            content: content,
            reasoning: reasoning,
            sources: sourcesJSON.flatMap { json in
                try? JSONDecoder().decode([Source].self, from: Data(json.utf8))
            },
            isSearching: isSearching,
            isError: isError,
            createdAt: createdAt
        )
    }
}

final class SessionStore: ObservableObject {
    /// 会话数据。setter 设为 private：所有 UI 通知改为显式
    /// `objectWillChange.send()`，流式写回（syncMessage）不会触发整树重算。
    private(set) var sessions: [ChatSession] = []

    private let directory: URL
    private let dbQueue: DatabaseQueue
    /// 消息 ID -> 消息状态。同一消息始终复用同一个状态对象，
    /// 保证流式更新只刷新该消息所在的视图。
    private var messageStates: [UUID: MessageState] = [:]

    init(
        storageDirectory: URL? = nil,
        saveDelay: Duration = .milliseconds(600)
    ) {
        // saveDelay 仅保留以兼容调用方：SQLite 改为逐行即时写入，
        // 不再需要“整库 JSON 编码 + 防抖落盘”，也就消除了长会话的编码瓶颈。
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
            NSLog("打开会话数据库失败，改用内存库: \(error)")
            dbQueue = try! DatabaseQueue(configuration: configuration)
        }
        do {
            try Self.migrator.migrate(dbQueue)
        } catch {
            NSLog("初始化数据库表失败: \(error)")
        }
        migrateLegacyDataIfNeeded()
        load()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.deepseek.chat", isDirectory: true)
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
            NSLog("读取会话失败: \(error)")
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
               let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
                legacySessions = decoded
            } else if let migrated = Migration.migrateSessions(from: directory.appendingPathComponent("state.json")) {
                legacySessions = migrated
            } else {
                legacySessions = nil
            }

            guard let legacySessions else { return }
            try dbQueue.write { db in
                for session in legacySessions {
                    var sessionRecord = SessionRecord(
                        id: session.id.uuidString,
                        title: session.title,
                        createdAt: session.createdAt,
                        updatedAt: session.updatedAt
                    )
                    try sessionRecord.insert(db)
                    for (position, message) in session.messages.enumerated() {
                        var messageRecord = makeMessageRecord(message, sessionID: session.id, position: position)
                        try messageRecord.insert(db)
                    }
                }
            }
        } catch {
            NSLog("迁移旧会话数据失败: \(error)")
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
            NSLog("创建会话写库失败: \(error)")
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
            NSLog("删除会话写库失败: \(error)")
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
            NSLog("重命名会话写库失败: \(error)")
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

    func appendMessage(sessionID: UUID, _ message: ChatMessage) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = Date()
        do {
            try dbQueue.write { db in
                let position = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM message WHERE sessionID = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
                var record = makeMessageRecord(message, sessionID: sessionID, position: position)
                try record.insert(db)
                try touchSession(db, sessionID: sessionID, updatedAt: sessions[index].updatedAt)
            }
        } catch {
            NSLog("追加消息写库失败: \(error)")
        }
        objectWillChange.send()
    }

    func updateMessage(sessionID: UUID, messageID: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard
            let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID })
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
            let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == state.id })
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
    private func persistMessage(_ message: ChatMessage, sessionID: UUID, position: Int, updatedAt: Date) {
        do {
            try dbQueue.write { db in
                var record = makeMessageRecord(message, sessionID: sessionID, position: position)
                try record.upsert(db)
                try touchSession(db, sessionID: sessionID, updatedAt: updatedAt)
            }
        } catch {
            NSLog("更新消息写库失败: \(error)")
        }
    }

    private func touchSession(_ db: Database, sessionID: UUID, updatedAt: Date) throws {
        try db.execute(
            sql: "UPDATE session SET updatedAt = ? WHERE id = ?",
            arguments: [updatedAt, sessionID.uuidString]
        )
    }

    private func makeMessageRecord(_ message: ChatMessage, sessionID: UUID, position: Int) -> MessageRecord {
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
}

final class SettingsStore: ObservableObject {
    @Published var model: String {
        didSet { defaults.set(model, forKey: "model") }
    }
    @Published var thinking: Bool {
        didSet { defaults.set(thinking, forKey: "thinking") }
    }
    @Published var effort: Effort {
        didSet { defaults.set(effort.rawValue, forKey: "effort") }
    }
    @Published var webSearch: Bool {
        didSet { defaults.set(webSearch, forKey: "webSearch") }
    }
    @Published var apiKey: String {
        didSet {
            if keychainSaveDelay == .zero {
                persistKey(value: apiKey)
            } else {
                keychainSaveTask?.cancel()
                let value = apiKey
                let delay = keychainSaveDelay
                // Keychain 写入可能阻塞，防抖后在后台线程执行
                keychainSaveTask = Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.persistKey(value: value)
                }
            }
        }
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStoring
    private let keychainSaveDelay: Duration
    private var keychainSaveTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore.shared,
        keychainSaveDelay: Duration = .milliseconds(600)
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.keychainSaveDelay = keychainSaveDelay
        let savedModel = defaults.string(forKey: "model") ?? "deepseek-v4-flash"
        model =
            savedModel == "deepseek-chat" || savedModel == "deepseek-reasoner"
            ? "deepseek-v4-flash"
            : savedModel
        thinking = defaults.object(forKey: "thinking") as? Bool ?? true
        effort = Effort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .high
        webSearch = defaults.bool(forKey: "webSearch")
        apiKey = keychain.read(account: "apiKey") ?? ""
    }

    var keyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persistKey(value: String) {
        if value.isEmpty {
            keychain.delete(account: "apiKey")
        } else {
            keychain.write(account: "apiKey", value: value)
        }
    }
}

protocol KeychainStoring {
    func read(account: String) -> String?
    func write(account: String, value: String)
    func delete(account: String)
}

struct KeychainStore: KeychainStoring {
    static let shared = KeychainStore()
    private static let service = "com.deepseek.chat"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
