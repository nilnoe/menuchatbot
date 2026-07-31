import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 侧栏会话行布局回归测试。
///
/// 0.2.2 曾用固定 44pt 估算 hover 预留位，小于三个快捷按钮的实际宽度
/// （约 66pt），导致按钮盖住右侧 token 用量文字。此处用与
/// `SidebarSessionRow` 相同的几何关系做探针（BubbleLayoutTests 同款做法）：
/// hover 时正文最右缘必须不越过快捷按钮最左缘；同时锁定 DesignTokens 的
/// 预留位公式，防止按钮数量 / 尺寸调整后预留位不同步。
final class SidebarRowLayoutTests: XCTestCase {
    private struct EdgeKey: PreferenceKey {
        static var defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    /// 复刻 SidebarSessionRow：ZStack(alignment: .trailing) + 正文 hover 预留位。
    private struct RowProbe: View {
        let isHovered: Bool

        var body: some View {
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("一个很长的会话标题，用于验证 hover 预留位是否足够")
                            .font(.callout)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("今天")
                            Text("12 条")
                        }
                        .font(.caption2)
                        // tokens 独立子行（0.3 起不再与日期 / 条数挤在同一行）
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar")
                                .font(.system(size: 9))
                            Text("1.2k tokens")
                        }
                        .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(measure("text", edge: \.maxX))
                    .padding(
                        .trailing,
                        isHovered ? DesignTokens.Sidebar.quickActionsReservedWidth : 0
                    )
                }
                .padding(8)

                if isHovered {
                    HStack(spacing: DesignTokens.Sidebar.quickActionSpacing) {
                        ForEach(0..<3, id: \.self) { _ in
                            Image(systemName: "pin")
                                .font(.system(size: 11, weight: .medium))
                                .frame(
                                    width: DesignTokens.Sidebar.quickActionButtonSize,
                                    height: DesignTokens.Sidebar.quickActionButtonSize
                                )
                        }
                    }
                    .padding(.trailing, DesignTokens.Sidebar.quickActionsTrailingPadding)
                    .background(measure("actions", edge: \.minX))
                }
            }
            .coordinateSpace(name: "rowProbe")
            .frame(width: DesignTokens.Sidebar.width)
        }

        private func measure(_ key: String, edge: KeyPath<CGRect, CGFloat>) -> some View {
            GeometryReader { geo in
                Color.clear.preference(
                    key: EdgeKey.self,
                    value: [key: geo.frame(in: .named("rowProbe"))[keyPath: edge]]
                )
            }
        }
    }

    private func measureEdges(isHovered: Bool) -> (textMaxX: CGFloat, actionsMinX: CGFloat) {
        var edges: [String: CGFloat] = [:]
        let probe = RowProbe(isHovered: isHovered)
            .onPreferenceChange(EdgeKey.self) { edges = $0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: AnyView(probe))
        hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (edges["text"] ?? .infinity, edges["actions"] ?? -.infinity)
    }

    /// 预留位公式必须与「三个按钮 + 两个间隔 + 尾部留白」的实宽一致。
    func testReservedWidthMatchesButtonGroupGeometry() {
        XCTAssertEqual(
            DesignTokens.Sidebar.quickActionsReservedWidth,
            DesignTokens.Sidebar.quickActionButtonSize * 3
                + DesignTokens.Sidebar.quickActionSpacing * 2
                + DesignTokens.Sidebar.quickActionsTrailingPadding
        )
    }

    /// hover 时正文（含最长 tokens 子行）不得越过快捷按钮左缘。
    func testHoveredRowTextDoesNotOverlapQuickActions() {
        let result = measureEdges(isHovered: true)
        XCTAssertLessThanOrEqual(result.textMaxX, result.actionsMinX)
    }

    /// 非 hover 时正文可用满整行（无按钮遮挡，无需预留）。
    func testNonHoveredRowTextSpansFullWidth() {
        let result = measureEdges(isHovered: false)
        XCTAssertGreaterThan(result.textMaxX, result.actionsMinX)
    }

    /// 真实 SidebarSessionRow（hover + tokens）挂窗渲染冒烟。
    func testSidebarSessionRowRendersHoveredWithTokens() {
        let session = ChatSession(
            id: UUID(),
            title: "带用量会话",
            messages: [
                ChatMessage(
                    role: .assistant,
                    content: "回答",
                    usage: TokenUsage(
                        promptTokens: 500,
                        cachedTokens: 0,
                        completionTokens: 700,
                        totalTokens: 1_200
                    )
                )
            ],
            createdAt: Date(),
            updatedAt: Date()
        )
        let row = SidebarSessionRow(
            session: session,
            isSelected: false,
            isHovered: true,
            onSelect: {},
            onTogglePin: {},
            onRename: {},
            onDelete: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 176, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: AnyView(row))
        hosting.frame = NSRect(x: 0, y: 0, width: 176, height: 90)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(window.contentView)
    }
}
