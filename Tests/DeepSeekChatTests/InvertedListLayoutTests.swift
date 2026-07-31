import SwiftUI
import XCTest

/// 倒置列表布局回归测试。
///
/// 复刻 ChatView 的倒置消息区结构（双旋转 + minHeight 顶置），
/// 用全局坐标断言：
/// 1. 顺序恒为正序（最旧在视觉顶部、最新在底部）；
/// 2. 短会话顶置（首条气泡贴视口顶部，不再沉底）；
/// 3. 长会话仍贴底跟随（滚动后最新消息在视口底部附近）。
final class InvertedListLayoutTests: XCTestCase {
    private struct RowPositionKey: PreferenceKey {
        static var defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    private struct Row: View {
        let id: String
        let text: String

        var body: some View {
            Text(text)
                .frame(width: 200, height: 40)
                .background(Color.gray.opacity(0.3))
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: RowPositionKey.self,
                            value: [id: geo.frame(in: .global).minY]
                        )
                    }
                )
        }
    }

    private func measure(
        rowCount: Int,
        viewportHeight: CGFloat,
        minHeight: CGFloat?
    ) -> [String: CGFloat] {
        let ids = (0..<rowCount).map { "row-\($0)" }
        var positions: [String: CGFloat] = [:]

        let content = ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(ids.reversed(), id: \.self) { id in
                        Row(id: id, text: id)
                            .rotationEffect(.degrees(180))
                    }
                }
                .padding(.vertical, 10)
                .frame(minHeight: minHeight ?? viewportHeight, alignment: .bottom)
                .rotationEffect(.degrees(180))
            }
            .coordinateSpace(name: "probeScroll")
            .defaultScrollAnchor(.bottom)
            .onAppear {
                if let newest = ids.last {
                    proxy.scrollTo(newest, anchor: .bottom)
                }
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: AnyView(
                content
                    .frame(width: 600, height: viewportHeight)
                    .onPreferenceChange(RowPositionKey.self) { positions = $0 }
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: viewportHeight)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        return positions
    }

    func testShortConversationPinnedToTop() {
        let positions = measure(rowCount: 3, viewportHeight: 300, minHeight: 300)
        XCTAssertEqual(positions.count, 3)
        // 首条（最旧）气泡顶到视口顶部附近，不再沉在视口中部/底部
        XCTAssertLessThan(positions["row-0"] ?? .infinity, 50)
        // 顺序恒为正序：最旧在视觉顶部、最新在底部
        XCTAssertLessThan(positions["row-0"] ?? .infinity, positions["row-2"] ?? -1)
    }

    func testLongConversationStaysBottomAnchored() {
        // 10 行内容（约 490pt）超出 300pt 视口，minHeight 失效 → 贴底跟随
        let positions = measure(rowCount: 10, viewportHeight: 300, minHeight: 300)
        XCTAssertEqual(positions.count, 10)
        let newest = positions["row-9"] ?? 0
        // 最新消息在视口底部附近（滚到底后 minY ≈ 视口高 - 行高 - 边距）
        XCTAssertGreaterThan(newest, 200)
        XCTAssertLessThan(newest, 280)
        XCTAssertLessThan(positions["row-0"] ?? .infinity, newest)
    }
}
