import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 气泡宽度布局回归测试。
///
/// 踩坑记录：`.frame(maxWidth:)` 直接放在 HStack + Spacer 里的气泡上会被撑满
/// （短文本也会占满整行）；放在 VStack 内层又会因理想宽度为 0 而塌陷。
/// 正确做法是「行级限宽」：限制整行宽度，气泡在行内自然贴合文字。
///
/// 0.3 起气泡上限改为「对话列占主区比例 × 气泡占列比例」的等比模型，
/// 窗口调整时对话与主区比例保持不变（0.2.x 固定 780pt 会让两侧空隙变化）。
final class BubbleLayoutTests: XCTestCase {
    private struct ProbeWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct Probe: View {
        let text: String
        let role: Role
        let availableWidth: CGFloat

        private var columnWidth: CGFloat {
            availableWidth * DesignTokens.messageColumnRatio
        }

        private var bubbleMaxWidth: CGFloat {
            columnWidth
                * (role == .user
                    ? DesignTokens.userBubbleColumnRatio
                    : DesignTokens.assistantBubbleColumnRatio)
        }

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 48)
                Text(text)
                    .font(.callout)
                    .padding(10)
                    .background(measureBackground)
                Image(systemName: "person.crop.circle.fill")
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
            .frame(width: availableWidth)
        }

        private var measureBackground: some View {
            GeometryReader { geo in
                Color.clear.preference(
                    key: ProbeWidthKey.self,
                    value: geo.size.width
                )
            }
        }
    }

    private func measureWidth(text: String, role: Role, availableWidth: CGFloat) -> CGFloat {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: availableWidth, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var width: CGFloat = 0
        let probe = Probe(text: text, role: role, availableWidth: availableWidth)
            .onPreferenceChange(ProbeWidthKey.self) { width = $0 }
        let hosting = NSHostingView(rootView: AnyView(probe))
        hosting.frame = NSRect(x: 0, y: 0, width: availableWidth, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return width
    }

    /// 短文本：气泡应贴合文字，而不是撑满整行。
    func testShortTextHugs() {
        let width = measureWidth(text: "你好", role: .user, availableWidth: 800)
        XCTAssertGreaterThan(width, 20)
        XCTAssertLessThan(width, 200)
    }

    /// 长文本：用户气泡在「列宽 × 比例」的限宽内换行，不撑破容器。
    func testLongTextWrapsAtProportionalUserBubbleCap() {
        let longText = String(repeating: "这是一段比较长的文字用于测试换行。", count: 20)
        let cap =
            800 * DesignTokens.messageColumnRatio * DesignTokens.userBubbleColumnRatio
        let width = measureWidth(text: longText, role: .user, availableWidth: 800)
        XCTAssertLessThanOrEqual(width, cap + 10)
        XCTAssertGreaterThan(width, cap * 0.6)
    }

    /// 长文本：assistant 气泡（更宽）在各自比例限宽内换行。
    func testLongTextWrapsAtProportionalAssistantBubbleCap() {
        let longText = String(repeating: "这是一段比较长的文字用于测试换行。", count: 20)
        let cap =
            800 * DesignTokens.messageColumnRatio * DesignTokens.assistantBubbleColumnRatio
        let width = measureWidth(text: longText, role: .assistant, availableWidth: 800)
        XCTAssertLessThanOrEqual(width, cap + 10)
        XCTAssertGreaterThan(width, cap * 0.6)
    }

    /// 对话列随主区宽度等比缩放：大窗口的气泡上限应按比例更宽，
    /// 保证「对话与主区比例」不变、两侧空隙等比变化。
    func testBubbleCapScalesProportionallyWithWindow() {
        let longText = String(repeating: "这是一段比较长的文字用于测试换行。", count: 20)
        let small = measureWidth(text: longText, role: .user, availableWidth: 800)
        let large = measureWidth(text: longText, role: .user, availableWidth: 1_200)
        XCTAssertGreaterThan(large, small * 1.3, "大窗口气泡上限应按比例更宽")
    }
}
