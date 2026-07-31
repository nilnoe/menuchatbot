import Foundation

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
