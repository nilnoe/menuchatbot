import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 完整 ChatView 渲染复现测试：真实挂窗口、走两轮对话流程、逐帧截图，
/// 用于定位「第二轮发送后消息区空白」。
@MainActor
final class ChatViewRenderTests: XCTestCase {
    private var tempDir: URL!
    private var store: SessionStore!
    private var settings: SettingsStore!
    private var controller: ChatStreamController!
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
        store = SessionStore(storageDirectory: tempDir)

        let keychain = MockKeychain()
        keychain.storage["apiKey"] = "test-key"
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: "ChatViewRender-\(UUID().uuidString)")!,
            keychain: keychain,
            keychainSaveDelay: .zero
        )
        controller = ChatStreamController(sessionStore: store, settings: settings)
        selectedBox = SelectedBox()
    }

    override func tearDownWithError() throws {
        window = nil
        hosting = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeChatView(streamingSessionID: UUID? = nil, streamingState: MessageState? = nil)
        -> ChatView
    {
        let binding = Binding<UUID?>(
            get: { [weak self] in self?.selectedBox.id },
            set: { [weak self] in self?.selectedBox.id = $0 }
        )
        controller.streamingSessionID = streamingSessionID
        controller.streamingState = streamingState
        return ChatView(selectedID: binding, onOpenSettings: {}, onToggleSidebar: {})
    }

    private func host(_ view: ChatView) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(
            rootView: AnyView(
                view
                    .environmentObject(store)
                    .environmentObject(settings)
                    .environmentObject(controller)
                    // 显式白色背景：无边框窗口默认渲染为透明/黑，会把整窗算成墨水
                    .background(Color.white)
            )
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
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return 0
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = Int(round(Double(rep.pixelsWide) / max(hosting.bounds.width, 1)))
        var dark = 0
        var total = 0
        // colorAt 使用像素坐标，需按位图缩放换算（retina 下为 2x）。
        for y in stride(from: 50 * scale, to: 430 * scale, by: 2 * scale) {
            for x in stride(from: 20 * scale, to: 620 * scale, by: 2 * scale) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                let lum =
                    0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if lum < 0.88 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    /// 统计消息区上半 / 下半的非背景像素占比，用于验证「短会话顶置」。
    /// 消息区扫描范围 y 60...400（避开顶部标题与底部输入框）。
    private func messageAreaInkByHalf() -> (top: Double, bottom: Double) {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return (0, 0)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = Int(round(Double(rep.pixelsWide) / max(hosting.bounds.width, 1)))
        var topDark = 0
        var bottomDark = 0
        var topTotal = 0
        var bottomTotal = 0
        for y in stride(from: 60 * scale, to: 400 * scale, by: 2 * scale) {
            for x in stride(from: 20 * scale, to: 620 * scale, by: 2 * scale) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let lum =
                    0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if lum < 0.88 {
                    if y < 230 * scale { topDark += 1 } else { bottomDark += 1 }
                }
                if y < 230 * scale { topTotal += 1 } else { bottomTotal += 1 }
            }
        }
        return (
            Double(topDark) / Double(max(topTotal, 1)),
            Double(bottomDark) / Double(max(bottomTotal, 1))
        )
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
            let document = scroll.documentView
        else { return nil }
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

    /// 短会话顶置：只有一两条消息时，气泡应贴在消息区顶部（上半墨水占比更高），
    /// 而不是沉在底部。这是「看起来像正序」的核心观感。
    func testShortConversationInkAtTop() throws {
        let session = store.createSession(title: "短会话")
        selectedBox.id = session.id
        host(makeChatView())
        settle()

        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "你好"))
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(role: .assistant, content: "你好！有什么可以帮你？")
        )
        settleUntilInk()
        try snapshot(named: "short-pinned-top")

        let (top, bottom) = messageAreaInkByHalf()
        print("SHORT-INK top=\(top) bottom=\(bottom)")
        XCTAssertGreaterThan(top, bottom, "短会话应顶置：首条气泡应在消息区上半部分")
    }

    /// 轮询等待消息区出现墨水（CI 慢环境防抖）：先渲染一帧再检查，
    /// 阈值避开空状态提示的少量墨水（~0.0005），最多 ~2s。
    private func settleUntilInk() {
        for _ in 0..<16 {
            settle()
            let ratio = messageAreaInkRatio()
            if ratio > 0.001 { return }
        }
    }

    /// 空状态（无消息）在消息区视口内垂直居中：
    /// 用加高窗口放大「固定 80pt 下移」与「视口居中」的差异，断言墨水带中心
    /// 落在消息区中段（旧实现会落在上段）。
    func testEmptyStateVerticallyCentered() throws {
        selectedBox.id = store.createSession(title: "空会话").id
        // 与 host() 相同的装配，仅窗口加高（消息区约 y 57...725，中点约 391）。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(
            rootView: AnyView(
                makeChatView()
                    .environmentObject(store)
                    .environmentObject(settings)
                    .environmentObject(controller)
                    .background(Color.white)
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        hosting.appearance = NSAppearance(named: .aqua)
        self.window = window
        settle()
        try snapshot(named: "empty-centered")

        // 扫描消息区墨水带的垂直范围（colorAt 为像素坐标，按缩放换算）。
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("无法生成位图")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = Int(round(Double(rep.pixelsWide) / max(hosting.bounds.width, 1)))
        var minY: Int = Int.max
        var maxY: Int = -1
        for y in stride(from: 60 * scale, to: 725 * scale, by: scale) {
            var rowDark = false
            for x in stride(from: 20 * scale, to: 620 * scale, by: 2 * scale) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let lum =
                    0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if lum < 0.88 {
                    rowDark = true
                    break
                }
            }
            if rowDark {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        XCTAssertNotEqual(minY, Int.max, "消息区应有空状态墨水")
        let center = (CGFloat(minY) + CGFloat(maxY)) / 2 / CGFloat(scale)
        print("EMPTY-CENTER minY=\(minY) maxY=\(maxY) center=\(center)")
        // 消息区约 57...725，中点 391；居中时墨水带中心应在中段。
        XCTAssertGreaterThan(center, 320, "空状态应居中（墨水带中心在中段）")
        XCTAssertLessThan(center, 470, "空状态应居中（墨水带中心在中段）")
        XCTAssertLessThan(
            (CGFloat(maxY) - CGFloat(minY)) / CGFloat(scale),
            400,
            "墨水带高度应接近空状态内容高度（而非整窗）"
        )
    }
}
