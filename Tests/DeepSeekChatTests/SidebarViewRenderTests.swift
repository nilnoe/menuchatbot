import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 侧栏（会话分组 + hover 快捷操作 + 会话图标）挂窗渲染冒烟。
final class SidebarViewRenderTests: XCTestCase {
    func testSidebarViewRendersWithSessions() {
        let defaults = UserDefaults(suiteName: "SidebarRender-\(UUID().uuidString)")!
        let settings = SettingsStore(
            defaults: defaults,
            keychain: MockKeychain(),
            keychainSaveDelay: .zero
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarRender-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionStore = SessionStore(storageDirectory: tempDir)

        // 普通会话 + 带参考来源（联网搜索过）的会话，覆盖两种图标路径。
        let plain = sessionStore.createSession(title: "普通会话")
        sessionStore.appendMessage(
            sessionID: plain.id,
            ChatMessage(role: .user, content: "你好")
        )
        let searched = sessionStore.createSession(title: "联网会话")
        sessionStore.appendMessage(
            sessionID: searched.id,
            ChatMessage(
                role: .assistant,
                content: "答案",
                sources: [Source(title: "来源", url: "https://example.com")]
            )
        )
        // 置顶会话应照常渲染在置顶分组中
        sessionStore.setPinned(id: plain.id, pinned: true)

        var selectedID: UUID? = plain.id
        var showSettings = false
        let selectedBinding = Binding<UUID?>(
            get: { selectedID },
            set: { selectedID = $0 }
        )
        let showSettingsBinding = Binding<Bool>(
            get: { showSettings },
            set: { showSettings = $0 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: AnyView(
                SidebarView(selectedID: selectedBinding, showSettings: showSettingsBinding)
                    .environmentObject(sessionStore)
                    .environmentObject(settings)
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotNil(window.contentView)
        XCTAssertEqual(sessionStore.sessions.count, 2)
        defaults.removePersistentDomain(forName: "SidebarRender")
    }
}
