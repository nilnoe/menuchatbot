import Foundation

/// 把旧版（Tauri）应用的会话数据迁移到原生版。
/// 旧数据路径：~/Library/Application Support/com.deepseek.chat/state.json
enum Migration {
    private struct LegacySource: Decodable {
        var title: String?
        var url: String?
    }

    private struct LegacyMessage: Decodable {
        var id: String
        var role: String
        var content: String
        var reasoning: String?
        var sources: [LegacySource]?
        var searching: Bool?
        var error: Bool?
        var createdAt: Double
    }

    private struct LegacySession: Decodable {
        var id: String
        var title: String
        var messages: [LegacyMessage]
        var createdAt: Double
        var updatedAt: Double
    }

    private struct LegacyState: Decodable {
        var sessions: [LegacySession]

        enum CodingKeys: String, CodingKey {
            case sessions = "deepseek-chat.sessions.v1"
        }
    }

    static func migrateSessions() -> [ChatSession]? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return migrateSessions(from: base.appendingPathComponent("com.deepseek.chat/state.json"))
    }

    static func migrateSessions(from fileURL: URL) -> [ChatSession]? {
        let oldFile = fileURL
        guard let data = try? Data(contentsOf: oldFile) else { return nil }
        guard let state = try? JSONDecoder().decode(LegacyState.self, from: data) else {
            return nil
        }

        return state.sessions.map { legacy in
            ChatSession(
                id: UUID(uuidString: legacy.id) ?? UUID(),
                title: legacy.title,
                messages: legacy.messages.map { message in
                    ChatMessage(
                        id: UUID(uuidString: message.id) ?? UUID(),
                        role: message.role == "user" ? .user : .assistant,
                        content: message.content,
                        reasoning: message.reasoning,
                        sources: message.sources?
                            .filter { !($0.url ?? "").isEmpty }
                            .map { Source(title: $0.title, url: $0.url ?? "") },
                        isSearching: false,
                        isError: message.error ?? false,
                        createdAt: Date(timeIntervalSince1970: message.createdAt / 1000)
                    )
                },
                createdAt: Date(timeIntervalSince1970: legacy.createdAt / 1000),
                updatedAt: Date(timeIntervalSince1970: legacy.updatedAt / 1000)
            )
        }
    }
}
