import Foundation

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
