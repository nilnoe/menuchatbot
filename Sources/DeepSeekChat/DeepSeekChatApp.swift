import AppKit
import SwiftUI

@main
struct DeepSeekChatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 菜单栏常驻应用：不占 Dock
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let sessionStore = SessionStore()
    private let settingsStore = SettingsStore()
    private lazy var streamController = ChatStreamController(
        sessionStore: sessionStore, settings: settingsStore)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupPanel()
    }

    /// 菜单栏应用也必须设置主菜单，否则 Cmd+C/V/X/A 等编辑快捷键不生效
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "关于 DeepSeek Chat",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "退出 DeepSeek Chat",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(
            NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        )
        editMenu.addItem(
            NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        )
        editMenu.addItem(
            NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        )
        editMenu.addItem(
            NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        )
        editMenu.addItem(
            NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        )
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "DeepSeek Chat"
        )
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(
            title: panel.isVisible ? "隐藏面板" : "显示面板",
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "退出 DeepSeek Chat",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleFromMenu() {
        togglePanel()
    }

    // MARK: - 面板窗口

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "DeepSeek Chat"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 640, height: 480)
        panel.delegate = self
        panel.isMovableByWindowBackground = false
        // 默认铺满可见区域约 93%（四周留边距，视觉舒展）；之后记住用户调整过的位置与大小。
        // autosave 名称从 mainPanel 升级为 mainPanelV2：旧版本保存的小窗口尺寸作废一次，
        // 让本次默认尺寸真正生效；用户重调后仍会按新名称记住。
        if !panel.setFrameUsingName(AppConfiguration.panelAutosaveName) {
            applyDefaultFrame()
        }
        panel.setFrameAutosaveName(AppConfiguration.panelAutosaveName)

        let root = ContentView()
            .environmentObject(sessionStore)
            .environmentObject(settingsStore)
            .environmentObject(streamController)
        // 统一系统表面风格：不叠加整窗毛玻璃。
        // 参考 ChatGPTUI / Messages 类聊天应用的惯例——系统底色 + 纯色组件，
        // 避免窗口材质与内部组件互相叠加造成风格割裂。
        panel.contentViewController = NSHostingController(rootView: root)
    }

    /// 默认尺寸：主屏可见区域（去掉菜单栏 / Dock）的 93%，居中
    private func applyDefaultFrame() {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(PanelSizing.defaultFrame(for: screen.visibleFrame), display: false)
    }

    /// 窗口默认尺寸计算（独立成纯函数，便于单测）。
    enum PanelSizing {
        /// 默认占可见区域的比值：铺满但四周留边距。
        static let defaultFillRatio: CGFloat = 0.93

        static func defaultFrame(for visible: NSRect) -> NSRect {
            let width = visible.width * defaultFillRatio
            let height = visible.height * defaultFillRatio
            return NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            if panel.isKeyWindow {
                panel.orderOut(nil)
            } else {
                // 面板可见但不在前台（如刚被点击过）时，重新激活而不是隐藏
                showPanel()
            }
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 面板上挂着子窗口（如系统菜单）时不隐藏
        if panel.attachedSheet != nil { return }
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
