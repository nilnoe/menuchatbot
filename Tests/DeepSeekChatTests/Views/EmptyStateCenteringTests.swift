import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 空状态垂直居中布局回归测试。
///
/// 0.2.2 用固定 `.padding(.top, 80)` 粗略下移，窗口高度变化时不真正居中；
/// 0.3 改为「用视口高度做 minHeight + alignment: .center」，随窗口高度实时
/// 重新居中。此处复刻 ChatView emptyState 的结构（BubbleLayoutTests 同款
/// 探针做法），断言内容中心始终落在视口垂直中点附近。
final class EmptyStateCenteringTests: XCTestCase {
    private struct CenterKey: PreferenceKey {
        static var defaultValue: CGFloat = -1
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct EmptyProbe: View {
        let viewport: CGFloat

        var body: some View {
            // 与 ChatView.messagesArea 相同的结构：GeometryReader 包裹提供
            // 真实视口尺寸（ScrollView 自身 background 测不到，见 ChatView 注释）。
            GeometryReader { geo in
                let viewportHeight = geo.size.height
                return ScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 36))
                        Text("DeepSeek Chat")
                            .font(.title2)
                        Text("开始一段新的对话")
                            .font(.callout)
                    }
                    // 与 ChatView emptyState 相同的居中策略：
                    // 用视口高度做 minHeight，alignment: .center 让内容随窗口高度居中。
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: CenterKey.self,
                                value: inner.frame(in: .named("emptyProbe")).midY
                            )
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: viewportHeight, alignment: .center)
                }
                .coordinateSpace(name: "emptyProbe")
            }
            .frame(width: 400, height: viewport)
        }
    }

    private func measure(viewport: CGFloat) -> CGFloat {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var center: CGFloat = -1
        let probe = EmptyProbe(viewport: viewport)
            .onPreferenceChange(CenterKey.self) { center = $0 }
        let hosting = NSHostingView(
            rootView: AnyView(probe)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: viewport)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        return center
    }

    func testEmptyStateCenteredInSmallViewport() {
        let center = measure(viewport: 300)
        XCTAssertEqual(center, 150, accuracy: 10)
    }

    func testEmptyStateCenteredInLargeViewport() {
        let center = measure(viewport: 700)
        XCTAssertEqual(center, 350, accuracy: 10)
    }
}
