import SwiftUI

/// 全局设计 token：字号、行高、间距、圆角、品牌色。
///
/// 统一排版规范，避免各处手写魔法数字。取值参考系统 HIG 的
/// caption / callout / body 字号梯度与 4pt 网格。
enum DesignTokens {
    // MARK: - 间距（4pt 网格）
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    // MARK: - 圆角
    enum Corner {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    // MARK: - 字号（caption / callout / body）
    enum FontSize {
        static let caption: CGFloat = 11
        static let callout: CGFloat = 13
        static let body: CGFloat = 14
    }

    /// 正文行高（1.5 倍），中文排版更透气。
    static let bodyLineHeight: CGFloat = 21

    /// 消息区最大宽度：大窗口下内容居中，避免整行被拉满。
    static let messageMaxWidth: CGFloat = 780

    /// 用户气泡最大宽度：短文本贴合文字，长文本在此宽度内换行。
    /// （不能把 maxWidth 直接放在 HStack 内的气泡上——实测会被撑满；
    /// 正确做法是限制整行宽度，让气泡在行内自然贴合。）
    static let userBubbleMaxWidth: CGFloat = 520

    /// assistant 气泡最大宽度（Markdown 阅读需要更宽）。
    static let assistantBubbleMaxWidth: CGFloat = 720

    /// 品牌渐变（蓝 → 紫）：只用于头像 / 点缀，不铺满。
    static let brandGradient = LinearGradient(
        colors: [.blue, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
