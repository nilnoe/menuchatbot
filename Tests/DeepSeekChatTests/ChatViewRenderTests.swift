import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekChat

/// 完整 ChatView 渲染复现测试：真实挂窗口、走两轮对话流程、逐帧截图，
/// 用于定位「第二轮发送后消息区空白」。
final class ChatViewRenderTests: XCTestCase {
    private var tempDir: URL!
    private var store: SessionStore!
    private var settings: SettingsStore!
    private var selectedBox: SelectedBox!
    private var window: NSWindow!
    private var hosting: NSHostingView<AnyView>!

    private final class SelectedBox {
        var id: UUID?
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewRender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SessionStore(storageDirectory: tempDir, saveDelay: .zero)

        let keychain = MockKeychain()
        keychain.storage["apiKey"] = "test-key"
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: "ChatViewRender-\(UUID().uuidString)")!,
            keychain: keychain,
            keychainSaveDelay: .zero
        )
        selectedBox = SelectedBox()
    }

    override func tearDownWithError() throws {
        window = nil
        hosting = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeChatView(streamingSessionID: UUID? = nil, streamingState: MessageState? = nil) -> ChatView {
        let binding = Binding<UUID?>(
            get: { [weak self] in self?.selectedBox.id },
            set: { [weak self] in self?.selectedBox.id = $0 }
        )
        var view = ChatView(selectedID: binding, onOpenSettings: {}, onToggleSidebar: {})
        view.streamingSessionID = streamingSessionID
        view.streamingState = streamingState
        return view
    }

    private func host(_ view: ChatView) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(
            rootView: AnyView(view.environmentObject(store).environmentObject(settings))
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        window.contentView = hosting
        // 强制浅色外观：白色背景，才能用「非白像素占比」判断消息区是否空白。
        window.appearance = NSAppearance(named: .aqua)
        hosting.appearance = NSAppearance(named: .aqua)
    }

    private func settle() {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        hosting.layoutSubtreeIfNeeded()
    }

    private func snapshot(named name: String) throws {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/chatview-\(name).png"))
        }
    }

    /// 统计消息区非背景像素占比；接近 0 说明消息区空白。
    private func messageAreaInkRatio() -> Double {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var dark = 0
        var total = 0
        for y in stride(from: 50, to: 430, by: 2) {
            for x in stride(from: 20, to: 620, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if lum < 0.88 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    /// 递归查找 SwiftUI ScrollView 底层的 NSScrollView，返回文档可见区与文档总尺寸。
    private func scrollMetrics() -> (visible: NSRect, document: NSRect)? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews {
                if let found = find(in: sub) { return found }
            }
            return nil
        }
        guard let scroll = find(in: hosting),
              let document = scroll.documentView else { return nil }
        return (scroll.documentVisibleRect, document.frame)
    }

    /// 滚动位置不得越界（内容下方出现空白视口的典型表现）。
    private func assertScrollWithinBounds(
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) {
        guard let metrics = scrollMetrics() else { return }
        XCTAssertLessThanOrEqual(
            metrics.visible.minY + metrics.visible.height,
            metrics.document.height + 1,
            "滚动越界：可见区超出文档底部",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            metrics.visible.minY,
            -1,
            "滚动越界：可见区超出文档顶部",
            file: file,
            line: line
        )
    }

    func testTwoCycleRenderDoesNotBlank() throws {
        let session = store.createSession(title: "测试会话")
        selectedBox.id = session.id
        host(makeChatView())
        settle()
        try snapshot(named: "0-empty")

        // 第一轮：高输出（单条长 markdown 回答，行高很大，贴近真实复现场景）
        let longAnswer = (1...300)
            .map { "第 \($0) 段：**加粗** 与 [链接](https://example.com/\($0))\n\n- 列表项 A\n- 列表项 B\n\n" }
            .joined()
        let u1 = ChatMessage(role: .user, content: "第一问")
        let a1 = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u1)
        store.appendMessage(sessionID: session.id, a1)
        let s1 = store.messageState(for: a1)
        s1.appendContent(longAnswer)
        s1.flushPending()
        store.commitMessage(s1, sessionID: session.id)
        settle()
        try snapshot(named: "1-after-conversation")
        assertScrollWithinBounds()

        // 第二轮发送：同一视图实例内追加，onChange 滚动路径真实触发
        let u2 = ChatMessage(role: .user, content: "第二问")
        let a2 = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u2)
        store.appendMessage(sessionID: session.id, a2)
        settle()
        try snapshot(named: "2-after-send")
        XCTAssertGreaterThan(messageAreaInkRatio(), 0.0005, "发送后消息区空白")
        assertScrollWithinBounds()

        // 流式增量
        let s2 = store.messageState(for: a2)
        s2.appendContent("第二段回答：**重要** 内容")
        s2.flushPending()
        settle()
        try snapshot(named: "3-streaming")
        XCTAssertGreaterThan(messageAreaInkRatio(), 0.0005, "流式中消息区空白")
        assertScrollWithinBounds()
    }

    /// 长会话（300 条历史）后再发送，消息区不应空白。
    func testLongConversationAppendDoesNotBlank() throws {
        let session = store.createSession(title: "长会话")
        selectedBox.id = session.id
        host(makeChatView())
        settle()
        // 单次挂载：保持同一视图实例，让 onChange 滚动路径真实触发。

        for i in 0..<300 {
            store.appendMessage(
                sessionID: session.id,
                ChatMessage(
                    role: i % 2 == 0 ? .user : .assistant,
                    content: "历史消息 \(i) 的内容，用于撑起长会话"
                )
            )
        }
        settle()
        if let metrics = scrollMetrics() {
            print("300 条后：visible=\(metrics.visible) document=\(metrics.document)")
        }

        // 用户处于底部（初始贴底），再次发送
        let u = ChatMessage(role: .user, content: "新问题")
        let a = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u)
        store.appendMessage(sessionID: session.id, a)
        settle()
        if let metrics = scrollMetrics() {
            print("再发送后：visible=\(metrics.visible) document=\(metrics.document)")
        }
        try snapshot(named: "long-after-send")
        XCTAssertGreaterThan(messageAreaInkRatio(), 0.0005, "长会话发送后消息区空白")
        assertScrollWithinBounds()

        let s = store.messageState(for: a)
        s.appendContent("长会话的新回答")
        s.flushPending()
        settle()
        try snapshot(named: "long-streaming")
        XCTAssertGreaterThan(messageAreaInkRatio(), 0.0005, "长会话流式中消息区空白")
        assertScrollWithinBounds()
    }

    /// 单条超长消息（> 2 万字，走截断保护）后再发送，不应空白。
    func testHugeSingleMessageDoesNotBlank() throws {
        let session = store.createSession(title: "超长单条")
        selectedBox.id = session.id
        host(makeChatView())

        let u1 = ChatMessage(role: .user, content: "第一问")
        let a1 = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u1)
        store.appendMessage(sessionID: session.id, a1)
        let s1 = store.messageState(for: a1)
        s1.appendContent(String(repeating: "超长内容段落，", count: 4_000))
        s1.flushPending()
        store.commitMessage(s1, sessionID: session.id)
        settle()
        try snapshot(named: "huge-after-conversation")

        let u2 = ChatMessage(role: .user, content: "第二问")
        let a2 = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, u2)
        store.appendMessage(sessionID: session.id, a2)
        let s2 = store.messageState(for: a2)
        host(makeChatView(streamingSessionID: session.id, streamingState: s2))
        settle()
        try snapshot(named: "huge-after-send")
        XCTAssertGreaterThan(messageAreaInkRatio(), 0.0005, "超长单条消息后发送，消息区空白")
    }
}
