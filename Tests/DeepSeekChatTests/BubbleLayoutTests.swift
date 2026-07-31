import SwiftUI
import XCTest

/// 气泡宽度布局回归测试。
///
/// 踩坑记录：`.frame(maxWidth:)` 直接放在 HStack + Spacer 里的气泡上会被撑满
/// （短文本也会占满整行）；放在 VStack 内层又会因理想宽度为 0 而塌陷。
/// 正确做法是「行级限宽」：限制整行宽度，气泡在行内自然贴合文字。
final class BubbleLayoutTests: XCTestCase {
    private struct ProbeWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct Probe: View {
        let text: String
        let maxWidth: CGFloat?

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 48)
                Text(text)
                    .font(.callout)
                    .padding(10)
                    .background(measureBackground)
                Image(systemName: "person.crop.circle.fill")
            }
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .frame(width: 780)
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

    private func measureWidth(text: String, maxWidth: CGFloat?) -> CGFloat {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var width: CGFloat = 0
        let probe = Probe(text: text, maxWidth: maxWidth)
            .onPreferenceChange(ProbeWidthKey.self) { width = $0 }
        let hosting = NSHostingView(rootView: AnyView(probe))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return width
    }

    /// 短文本：气泡应贴合文字，而不是撑满整行。
    func testShortTextHugsWithoutMaxWidth() {
        let width = measureWidth(text: "你好", maxWidth: nil)
        XCTAssertLessThan(width, 200)
    }

    /// 长文本：不加 maxWidth 时在可用宽度内换行，不撑破容器。
    func testLongTextWrapsWithoutMaxWidth() {
        let longText = String(repeating: "这是一段比较长的文字用于测试换行。", count: 20)
        let width = measureWidth(text: longText, maxWidth: nil)
        XCTAssertLessThanOrEqual(width, 700)
    }

    /// 行级限宽 + 短文本：气泡仍贴合文字。
    func testRowCappedHugsShortText() {
        let width = measureWidth(text: "你好", maxWidth: 520)
        XCTAssertGreaterThan(width, 20)
        XCTAssertLessThan(width, 200)
    }

    /// 行级限宽 + 长文本：气泡在限宽内换行。
    func testRowCappedLimitsLongText() {
        let longText = String(repeating: "这是一段比较长的文字用于测试换行。", count: 20)
        let width = measureWidth(text: longText, maxWidth: 520)
        XCTAssertLessThanOrEqual(width, 530)
        XCTAssertGreaterThan(width, 400)
    }
}
