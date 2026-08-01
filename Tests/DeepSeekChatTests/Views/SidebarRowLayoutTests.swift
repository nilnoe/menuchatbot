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

    /// 复刻 SidebarSessionRow：行内容与快捷按钮「并排」HStack（不再 ZStack 重叠）。
    private struct RowProbe: View {
        let showsActions: Bool

        var body: some View {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("一个很长的会话标题，用于验证快捷按钮不遮挡正文")
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
                }
                .padding(8)
                .frame(maxWidth: .infinity)

                if showsActions {
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

    private func measureEdges(showsActions: Bool) -> (textMaxX: CGFloat, actionsMinX: CGFloat) {
        var edges: [String: CGFloat] = [:]
        let probe = RowProbe(showsActions: showsActions)
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

    /// 显示快捷按钮时正文（含最长 tokens 子行）不得越过按钮左缘。
    func testRowTextDoesNotOverlapQuickActions() {
        let result = measureEdges(showsActions: true)
        XCTAssertLessThanOrEqual(result.textMaxX, result.actionsMinX)
    }

    /// 无快捷按钮时正文可用满整行。
    func testRowTextSpansFullWidthWithoutActions() {
        let result = measureEdges(showsActions: false)
        XCTAssertGreaterThan(result.textMaxX, result.actionsMinX)
    }

    /// 真实 SidebarSessionRow（选中常显快捷操作 + tokens）挂窗渲染冒烟。
    func testSidebarSessionRowRendersSelectedWithTokens() {
        let summary = SessionSummary(
            id: UUID(),
            title: "带用量会话",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: false,
            messageCount: 1,
            totalTokens: 1_200,
            lastMessageHasSources: false
        )
        let row = SidebarSessionRow(
            summary: summary,
            isSelected: true,
            onSelect: {},
            onTogglePin: {},
            onRename: {},
            onRenameConfirm: {},
            onRenameCancel: {},
            onDelete: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Sidebar.width, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: AnyView(row))
        hosting.frame = NSRect(x: 0, y: 0, width: DesignTokens.Sidebar.width, height: 90)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(window.contentView)
    }

    /// 行内重命名状态渲染冒烟：标题变为输入框、右侧为确定 / 取消。
    func testSidebarSessionRowRendersRenaming() {
        let summary = SessionSummary(
            id: UUID(),
            title: "旧标题",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: false,
            messageCount: 0,
            totalTokens: 0,
            lastMessageHasSources: false
        )
        var draft = "新标题"
        let row = SidebarSessionRow(
            summary: summary,
            isSelected: true,
            isRenaming: true,
            renameDraft: Binding(get: { draft }, set: { draft = $0 }),
            onSelect: {},
            onTogglePin: {},
            onRename: {},
            onRenameConfirm: {},
            onRenameCancel: {},
            onDelete: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Sidebar.width, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: AnyView(row))
        hosting.frame = NSRect(x: 0, y: 0, width: DesignTokens.Sidebar.width, height: 90)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(window.contentView)
    }

    // MARK: - 快捷操作可见性规则（选中行常显 / hover 由行自身管理）

    private func makeRow(isSelected: Bool) -> SidebarSessionRow {
        let summary = SessionSummary(
            id: UUID(),
            title: "测试会话",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: true,
            messageCount: 0,
            totalTokens: 0,
            lastMessageHasSources: false
        )
        return SidebarSessionRow(
            summary: summary,
            isSelected: isSelected,
            onSelect: {},
            onTogglePin: {},
            onRename: {},
            onRenameConfirm: {},
            onRenameCancel: {},
            onDelete: {}
        )
    }

    /// 选中行无需 hover 也显示快捷按钮：保证置顶 / 重命名 / 删除可发现。
    func testQuickActionsShownWhenSelectedWithoutHover() {
        XCTAssertTrue(makeRow(isSelected: true).showsQuickActions)
    }

    func testQuickActionsHiddenForUnselectedUnhoveredRow() {
        XCTAssertFalse(makeRow(isSelected: false).showsQuickActions)
    }

    // MARK: - 快捷按钮样式回归（2026-08-01 实测定位）

    /// 源码守卫：快捷按钮必须用 plain 样式。macOS 实测（2026-08-01）borderless
    /// 按钮在 ScrollView + LazyVStack 中点击无响应（事件进入手势追踪后不触发
    /// action），plain / bordered 均正常；曾因误判从 plain 改成 borderless
    /// 导致真机快捷按钮点击失效。防止该回归再次发生。
    func testQuickActionButtonsUsePlainStyleInSource() {
        let sourceURL = URL(fileURLWithPath: "Sources/DeepSeekChat/Views/SidebarView.swift")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            XCTFail("无法读取 SidebarView.swift（测试需从包根目录运行）")
            return
        }
        let quickActionRange =
            source.range(of: "quickActionButton")?.upperBound
            ?? source.startIndex
        let tail = source[quickActionRange...]
        XCTAssertTrue(
            tail.contains(".buttonStyle(.plain)"),
            "快捷按钮必须使用 .plain 样式（borderless 在 ScrollView 内点击无响应）"
        )
        XCTAssertFalse(
            tail.contains(".buttonStyle(.borderless)"),
            "快捷按钮不得使用 .borderless（macOS 实测在侧栏滚动列表中点击无响应）"
        )
    }
}
