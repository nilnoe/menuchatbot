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

    // MARK: - 对话内容列（随主区宽度等比缩放）

    /// 对话列占主区宽度的比例：窗口调整时「对话与主区」比例保持不变，
    /// 两侧空隙各占 (1 - ratio) / 2，随窗口等比缩放。
    /// （0.2.x 的固定 780pt 上限会导致大窗口两侧空隙变大。）
    static let messageColumnRatio: CGFloat = 0.86

    /// 用户气泡占对话列宽的比例：短文本仍贴合文字，长文本在此比例内换行。
    /// （不能把 maxWidth 直接放在 HStack 内的气泡上——实测会被撑满；
    /// 正确做法是限制整行宽度，让气泡在行内自然贴合。）
    static let userBubbleColumnRatio: CGFloat = 0.66

    /// assistant 气泡占对话列宽的比例（Markdown 阅读需要更宽）。
    static let assistantBubbleColumnRatio: CGFloat = 0.92

    /// 参考列宽：MessageView 未传入 columnWidth 时的回退值
    /// （约等于 0.2.x 的固定 780pt 设计；生产环境由 ChatView 按窗口传入）。
    static let referenceColumnWidth: CGFloat = 780

    // MARK: - 侧栏（会话列表）
    enum Sidebar {
        /// 侧栏固定宽度（ContentView 引用；调宽只改这里）。
        static let width: CGFloat = 176

        /// hover 快捷按钮组：置顶 / 重命名 / 删除。
        static let quickActionButtonSize: CGFloat = 22
        static let quickActionSpacing: CGFloat = 2
        static let quickActionsTrailingPadding: CGFloat = 8

        /// 三个快捷按钮 + 间隔 + 尾部留白的总宽度。
        /// hover 时正文据此预留位，保证文字不被按钮覆盖（与实测按钮组宽度一致）。
        static var quickActionsReservedWidth: CGFloat {
            quickActionButtonSize * 3 + quickActionSpacing * 2 + quickActionsTrailingPadding
        }
    }

    /// 品牌渐变（蓝 → 紫）：只用于头像 / 点缀，不铺满。
    static let brandGradient = LinearGradient(
        colors: [.blue, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
