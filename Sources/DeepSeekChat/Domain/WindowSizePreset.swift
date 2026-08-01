import Foundation

/// 窗口大小预设档位：以「占主屏可见区域的比例」定义。
///
/// 用户在设置页选择后持久化到 UserDefaults，每次启动按所选档位生效，
/// 不再被 autosave 恢复的旧窗口 frame 覆盖（见 PanelController）。
enum WindowSizePreset: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    /// 占主屏可见区域的比例（PanelSizing 据此计算居中 frame）。
    var fillRatio: CGFloat {
        switch self {
        case .compact: return 0.70
        case .standard: return 0.85
        case .large: return 0.93
        }
    }

    var label: String {
        switch self {
        case .compact: return "紧凑（70%）"
        case .standard: return "标准（85%）"
        case .large: return "铺满（93%）"
        }
    }
}
