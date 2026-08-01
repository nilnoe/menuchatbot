import Foundation

/// 命名资料库（ADR-0005 D1）：名称 + 路径 + 启用开关 + 访问授权。
struct LibraryCorpus: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var path: String
    var isEnabled: Bool
    /// security-scoped bookmark：目录授权持久化（TCC 首次授权后免重复弹窗）。
    var bookmarkData: Data?
}

/// 长时推演时长档位（ADR-0007 D3：时间预算驱动）。
enum DeliberationDuration: String, Codable, CaseIterable, Identifiable {
    case minutes5 = "5"
    case minutes10 = "10"
    case minutes20 = "20"
    case minutes30 = "30"

    var id: String { rawValue }

    var minutes: Int {
        switch self {
        case .minutes5: return 5
        case .minutes10: return 10
        case .minutes20: return 20
        case .minutes30: return 30
        }
    }

    var label: String { "\(minutes) 分钟" }
}
