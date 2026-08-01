import AppKit
import SwiftUI
import XCTest

@testable import DeepSeekChat

/// 设置页不应改变窗口尺寸的回归测试。
///
/// 0.3 曾把 SettingsView 固定为 420pt 宽——SwiftUI 内容的固有宽度变化会把
/// NSPanel 拽窄（autosave 还会记住窄尺寸），返回主界面后窗口无法恢复原大小。
/// 设置页改为「撑满窗口 + 表单限宽 420 居中」后，窗口尺寸应保持不变。
@MainActor
final class SettingsWindowSizeTests: XCTestCase {
    func testSwitchingToSettingsKeepsPanelSize() {
        let defaults = UserDefaults(suiteName: "SettingsWindow-\(UUID().uuidString)")!
        let settings = SettingsStore(
            defaults: defaults,
            keychain: MockKeychain(),
            keychainSaveDelay: .zero
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsWindow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SessionStore(storageDirectory: tempDir)
        let controller = ChatStreamController(sessionStore: store, settings: settings)
        let auditCenter = AuditCenter(directory: tempDir)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(
            rootView: AnyView(
                ContentView()
                    .environmentObject(store)
                    .environmentObject(settings)
                    .environmentObject(controller)
                    .environmentObject(auditCenter)
            )
        )
        panel.contentViewController = hosting
        panel.setFrame(NSRect(x: 0, y: 0, width: 1_000, height: 700), display: false)
        panel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = panel.frame.size

        // 模拟点击设置后内容切换（与 ContentView 内部 showSettings 切换等价）。
        hosting.rootView = AnyView(
            SettingsView(onClose: {})
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(auditCenter)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let after = panel.frame.size

        XCTAssertEqual(after.width, before.width, accuracy: 1, "打开设置不应改变窗口宽度")
        XCTAssertEqual(after.height, before.height, accuracy: 1, "打开设置不应改变窗口高度")
        panel.orderOut(nil)
        defaults.removePersistentDomain(forName: "SettingsWindow")
    }
}
