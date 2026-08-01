import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 设置页（卡片化分组 + Key 显示/隐藏 + 测试连接按钮）挂窗渲染冒烟。
final class SettingsViewRenderTests: XCTestCase {
    func testSettingsViewRenders() {
        let defaults = UserDefaults(suiteName: "SettingsRender-\(UUID().uuidString)")!
        let settings = SettingsStore(
            defaults: defaults,
            keychain: MockKeychain(),
            keychainSaveDelay: .zero
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsRender-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionStore = SessionStore(storageDirectory: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: AnyView(
                SettingsView(onClose: {})
                    .environmentObject(settings)
                    .environmentObject(sessionStore)
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 640)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotNil(window.contentView)
        defaults.removePersistentDomain(forName: "SettingsRender")
    }
}
