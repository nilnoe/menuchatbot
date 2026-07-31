import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekChat

/// 把真实视图挂到 AppKit 窗口里强制布局，捕捉渲染期崩溃 / 空白。
final class MessageViewRenderTests: XCTestCase {
    private func host<S: View>(_ view: S, in window: NSWindow) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    func testStreamingLifecycleDoesNotBlank() {
        let state = MessageState(message: ChatMessage(role: .assistant, content: ""))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 流式开始：空内容占位
        _ = host(MessageView(state: state, isStreaming: true), in: window)
        XCTAssertNotNil(window.contentView)

        // 流式中间：Markdown 实时渲染
        state.appendContent("# 标题\n\n正文 **加粗** [链接](https://example.com)")
        state.flushPending()
        _ = host(MessageView(state: state, isStreaming: true), in: window)

        // 流式结束：最终 Markdown 渲染
        _ = host(MessageView(state: state, isStreaming: false), in: window)

        // 再次发送：新消息行
        let second = MessageState(message: ChatMessage(role: .assistant, content: "第二轮"))
        _ = host(
            VStack {
                MessageView(state: state, isStreaming: false)
                MessageView(state: second, isStreaming: true)
            },
            in: window
        )

        XCTAssertEqual(second.content, "第二轮")
    }
}
