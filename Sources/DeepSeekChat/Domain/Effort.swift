import Foundation

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
