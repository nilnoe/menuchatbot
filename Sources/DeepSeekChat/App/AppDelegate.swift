import AppKit
import SwiftUI

/// 应用生命周期与装配（Composition Root）：
/// 创建 store / 控制器，组装主菜单、状态栏图标与主面板。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sessionStore = SessionStore()
    private let settingsStore = SettingsStore()
    private lazy var streamController = ChatStreamController(
        sessionStore: sessionStore, settings: settingsStore)
    private lazy var panelController = PanelController()
    private lazy var statusItemController = StatusItemController(
        panelVisible: { [weak self] in self?.panelController.panel.isVisible ?? false },
        onTogglePanel: { [weak self] in self?.panelController.toggle() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build()
        statusItemController.install()

        let root = ContentView()
            .environmentObject(sessionStore)
            .environmentObject(settingsStore)
            .environmentObject(streamController)
        // 统一系统表面风格：不叠加整窗毛玻璃。
        // 参考 ChatGPTUI / Messages 类聊天应用的惯例——系统底色 + 纯色组件，
        // 避免窗口材质与内部组件互相叠加造成风格割裂。
        let hosting = NSHostingController(rootView: root)
        panelController.install(contentViewController: hosting)
    }
}
