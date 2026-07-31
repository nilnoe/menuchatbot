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
    var isSearching: Bool
    var isError: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String? = nil,
        sources: [Source]? = nil,
        isSearching: Bool = false,
        isError: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.sources = sources
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
}

/// 会话导入 / 导出的 JSON 包装格式。
///
/// 带格式标识与版本号，避免未来数据结构变化时无法识别旧文件。
