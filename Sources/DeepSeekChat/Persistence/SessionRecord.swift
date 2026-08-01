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
    var isPinned: Bool
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
    /// 工具调用 JSON（assistant 消息；T2-3 透明展示 + 回传 API）。
    var toolCallsJSON: String?
    /// tool 角色消息：对应工具调用 ID。
    var toolCallID: String?
    /// tool 角色消息：工具名。
    var toolName: String?
    var isSearching: Bool
    var isError: Bool
    var createdAt: Date
    var position: Int
    /// 派生列（v4）：usage.totalTokens 的冗余，供侧栏聚合（Tier 1-2）。
    var tokenTotal: Int
    /// 派生列（v4）：内容指纹，供索引幂等与变更检测（Tier 1-2）。
    var contentHash: String
    /// 派生列（v4）：索引版本，索引成功后更新（Tier 1-2）。
    var indexVersion: Int

    var chatMessage: ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            role: role == "user" ? .user : (role == "tool" ? .tool : .assistant),
            content: content,
            reasoning: reasoning,
            sources: sourcesJSON.flatMap { json in
                try? JSONDecoder().decode([Source].self, from: Data(json.utf8))
            },
            usage: usageJSON.flatMap { json in
                try? JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
            },
            toolCalls: toolCallsJSON.flatMap { json in
                try? JSONDecoder().decode([ChatToolCall].self, from: Data(json.utf8))
            },
            toolCallID: toolCallID,
            toolName: toolName,
            isSearching: isSearching,
            isError: isError,
            createdAt: createdAt
        )
    }
}
