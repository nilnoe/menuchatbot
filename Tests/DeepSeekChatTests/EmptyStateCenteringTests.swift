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

    private struct ViewportKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct EmptyProbe: View {
        let viewport: CGFloat
        @State private var measuredViewport: CGFloat = 0
        @State private var contentCenter: CGFloat = -1

        var body: some View {
            ScrollView {
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
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: CenterKey.self,
                            value: geo.frame(in: .named("emptyProbe")).midY
                        )
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: measuredViewport, alignment: .center)
            }
            .coordinateSpace(name: "emptyProbe")
            .frame(width: 400, height: viewport)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ViewportKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onPreferenceChange(ViewportKey.self) { measuredViewport = $0 }
            .onPreferenceChange(CenterKey.self) { contentCenter = $0 }
        }
    }

    private func measure(viewport: CGFloat) -> (center: CGFloat, viewport: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var center: CGFloat = -1
        var measuredViewport: CGFloat = 0
        let probe = EmptyProbe(viewport: viewport)
            .onPreferenceChange(CenterKey.self) { center = $0 }
            .onPreferenceChange(ViewportKey.self) { measuredViewport = $0 }
        let hosting = NSHostingView(
            rootView: AnyView(probe)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: viewport)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        return (center, measuredViewport)
    }

    func testEmptyStateCenteredInSmallViewport() {
        let result = measure(viewport: 300)
        XCTAssertEqual(result.viewport, 300, accuracy: 1)
        XCTAssertEqual(result.center, result.viewport / 2, accuracy: 10)
    }

    func testEmptyStateCenteredInLargeViewport() {
        let result = measure(viewport: 700)
        XCTAssertEqual(result.viewport, 700, accuracy: 1)
        XCTAssertEqual(result.center, result.viewport / 2, accuracy: 10)
    }
}
