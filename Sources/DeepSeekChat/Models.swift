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

struct APIMessage: Codable {
    var role: String
    var content: String
}

struct ModelInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var supportsResponses: Bool

    static let all: [ModelInfo] = [
        ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", supportsResponses: true),
        ModelInfo(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro（Preview）", supportsResponses: false)
    ]

    static func info(_ id: String) -> ModelInfo {
        all.first { $0.id == id } ?? all[0]
    }
}

enum Effort: String, CaseIterable, Identifiable {
    case low
    case high
    case max

    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "低"
        case .high: return "高"
        case .max: return "Max"
        }
    }
}
