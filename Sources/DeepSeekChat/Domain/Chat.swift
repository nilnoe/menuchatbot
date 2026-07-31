import Foundation

enum Role: String, Codable, Equatable {
    case user
    case assistant
}

struct Source: Codable, Equatable, Hashable, Identifiable {
    var title: String?
    var url: String
    var id: String { url }
}

struct ChatMessage: Codable, Equatable, Identifiable {
    var id: UUID
    var role: Role
    var content: String
    var reasoning: String?
    var sources: [Source]?
    /// 该回复的 token 用量（assistant 消息流式结束后由 API 返回）。
    var usage: TokenUsage?
    var isSearching: Bool
    var isError: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String? = nil,
        sources: [Source]? = nil,
        usage: TokenUsage? = nil,
        isSearching: Bool = false,
        isError: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.sources = sources
        self.usage = usage
        self.isSearching = isSearching
        self.isError = isError
        self.createdAt = createdAt
    }
}

struct ChatSession: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    /// 会话是否置顶（侧栏置顶分组）。
    var isPinned: Bool = false

    init(
        id: UUID,
        title: String,
        messages: [ChatMessage],
        createdAt: Date,
        updatedAt: Date,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case messages
        case createdAt
        case updatedAt
        case isPinned
    }

    /// 旧备份（无 isPinned 字段）解码为未置顶，保证导入兼容。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isPinned, forKey: .isPinned)
    }
}

/// 会话导入 / 导出的 JSON 包装格式。
///
/// 带格式标识与版本号，避免未来数据结构变化时无法识别旧文件。
