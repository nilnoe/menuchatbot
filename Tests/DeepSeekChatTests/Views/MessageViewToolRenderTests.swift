import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 工具消息 / 工具调用清单渲染冒烟（T2-3c 透明展示）。
final class MessageViewToolRenderTests: XCTestCase {
    private func host<S: View>(_ view: S, in window: NSWindow) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    func testToolMessageRendersWithoutCrash() {
        let state = MessageState(
            message: ChatMessage(
                role: .tool,
                content: "结果：3",
                toolCallID: "call_1",
                toolName: "calculator"
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        _ = host(MessageView(state: state, isStreaming: false), in: window)
        XCTAssertEqual(state.toolName, "calculator")
        XCTAssertEqual(state.content, "结果：3")
    }

    func testAssistantWithToolCallsRendersWithoutCrash() {
        let state = MessageState(
            message: ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    ChatToolCall(
                        id: "call_1",
                        name: "calculator",
                        arguments: #"{"expr":"1+2"}"#
                    )
                ]
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        _ = host(MessageView(state: state, isStreaming: false), in: window)
        XCTAssertEqual(state.toolCalls?.first?.name, "calculator")
    }
}
