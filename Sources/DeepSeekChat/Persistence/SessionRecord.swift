import Foundation
import GRDB

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
    var usageJSON: String?
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
            usage: usageJSON.flatMap { json in
                try? JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
            },
            isSearching: isSearching,
            isError: isError,
            createdAt: createdAt
        )
    }
}
