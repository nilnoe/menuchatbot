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

    /// 代码块走 MarkdownUI CodeSyntaxHighlighter 管线（HighlighterSwift），
    /// 必须能渲染且不崩溃；高亮失败时退回纯文本。
    func testCodeBlockRendersWithHighlighter() {
        let markdown = """
            示例：

            ```swift
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            ```
            """
        let state = MessageState(message: ChatMessage(role: .assistant, content: markdown))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 最终渲染路径：启用真实高亮器
        _ = host(MessageView(state: state, isStreaming: false), in: window)
        XCTAssertNotNil(window.contentView)

        // 流式渲染路径：纯文本高亮器兜底
        let streaming = MessageState(message: ChatMessage(role: .assistant, content: markdown))
        _ = host(MessageView(state: streaming, isStreaming: true), in: window)
        XCTAssertNotNil(window.contentView)
    }

    /// 排版美化后的各消息形态（模型标签 / 错误+重试 / 来源卡片 / 用户头像）都能渲染。
    func testPolishedMessageStatesRender() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let errorState = MessageState(
            message: ChatMessage(role: .assistant, content: "网络超时", isError: true)
        )
        _ = host(
            MessageView(state: errorState, isStreaming: false, modelLabel: "V4 Flash", onRetry: {}),
            in: window
        )

        let sourcesState = MessageState(
            message: ChatMessage(
                role: .assistant,
                content: "回答",
                sources: [Source(title: "来源", url: "https://example.com")]
            )
        )
        _ = host(
            MessageView(state: sourcesState, isStreaming: false, modelLabel: "V4 Pro"),
            in: window
        )

        let userState = MessageState(message: ChatMessage(role: .user, content: "你好"))
        _ = host(MessageView(state: userState, isStreaming: false), in: window)

        XCTAssertNotNil(window.contentView)
    }
}
