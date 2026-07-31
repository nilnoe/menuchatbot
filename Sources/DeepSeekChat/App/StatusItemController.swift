import AppKit

/// 菜单栏图标控制器：状态栏图标、左/右键行为与上下文菜单。
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private let panelVisible: () -> Bool
    private let onTogglePanel: () -> Void

    init(
        panelVisible: @escaping () -> Bool,
        onTogglePanel: @escaping () -> Void
    ) {
        self.panelVisible = panelVisible
        self.onTogglePanel = onTogglePanel
    }

    func install() {
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
            onTogglePanel()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            onTogglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(
            title: panelVisible() ? "隐藏面板" : "显示面板",
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
        onTogglePanel()
    }
}
