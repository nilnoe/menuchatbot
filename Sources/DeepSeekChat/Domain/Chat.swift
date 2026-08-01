import Foundation

enum Role: String, Codable, Equatable {
    case user
    case assistant
    /// 工具执行结果消息（T2-3：透明展示，写入会话历史）。
    case tool
}

struct Source: Codable, Equatable, Hashable, Identifiable {
    var title: String?
    var url: String
    var id: String { url }
}

/// 会话内工具调用（assistant 消息上，用于透明展示与回传 API）。
struct ChatToolCall: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// 参数 JSON 文本。
    var arguments: String
}

struct ChatMessage: Codable, Equatable, Identifiable {
    var id: UUID
    var role: Role
    var content: String
    var reasoning: String?
    var sources: [Source]?
    /// 该回复的 token 用量（assistant 消息流式结束后由 API 返回）。
    var usage: TokenUsage?
    /// assistant 消息发起的工具调用（透明展示，T2-3c）。
    var toolCalls: [ChatToolCall]?
    /// tool 角色消息：对应工具调用 ID。
    var toolCallID: String?
    /// tool 角色消息：工具名。
    var toolName: String?
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
        toolCalls: [ChatToolCall]? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
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
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
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

/// 会话列表项（侧栏数据源）：仅元数据，**不持有消息正文**。
///
/// Tier 1-1 拆分：内存 / 存储模型解耦后，列表与侧栏只依赖本结构；
/// 消息正文按需经 `SessionStore.messages(for:)` 惰性加载并分页缓存。
struct SessionSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    /// 消息条数（SQL 聚合，随写入维护）。
    var messageCount: Int
    /// token 合计（来自派生列 tokenTotal，非逐条遍历）。
    var totalTokens: Int
    /// 最后一条消息是否带参考来源（侧栏图标：地球 vs 气泡）。
    var lastMessageHasSources: Bool
}

/// 会话导入 / 导出的 JSON 包装格式。
///
/// 带格式标识与版本号，避免未来数据结构变化时无法识别旧文件。
