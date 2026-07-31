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
struct SessionExport: Codable, Equatable {
    static let formatID = "deepseek-chat-sessions"
    static let currentVersion = 1

    var format: String
    var version: Int
    var app: String
    var exportedAt: Date
    var sessions: [ChatSession]

    init(exportedAt: Date = Date(), sessions: [ChatSession]) {
        self.format = Self.formatID
        self.version = Self.currentVersion
        self.app = "DeepSeek Chat"
        self.exportedAt = exportedAt
        self.sessions = sessions
    }
}

/// 导入结果统计。
struct SessionImportResult: Equatable {
    var importedSessions: Int
    var importedMessages: Int
}

enum SessionImportError: LocalizedError {
    case unsupportedFormat
    case unsupportedVersion(Int)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "文件不是 DeepSeek Chat 会话备份（缺少格式标识）"
        case .unsupportedVersion(let version):
            return "备份版本 \(version) 不受当前版本支持"
        case .decodingFailed(let reason):
            return "备份文件解析失败：\(reason)"
        }
    }
}

struct APIMessage: Codable {
    var role: String
    var content: String
}

struct ModelInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var supportsResponses: Bool

    /// 消息气泡上展示的短标签。
    var shortName: String {
        switch id {
        case "deepseek-v4-pro": return "V4 Pro"
        default: return "V4 Flash"
        }
    }

    static let all: [ModelInfo] = [
        ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", supportsResponses: true),
        ModelInfo(
            id: "deepseek-v4-pro", name: "DeepSeek V4 Pro（Preview）", supportsResponses: false),
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
