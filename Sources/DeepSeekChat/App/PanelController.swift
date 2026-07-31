import AppKit

/// 主面板窗口控制器：NSPanel 配置、默认尺寸、显示/隐藏与失去焦点收起。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel!

    /// 安装面板并挂载内容视图控制器。
    func install(contentViewController: NSViewController) {
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
        panel.contentViewController = contentViewController
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

    func toggle() {
        guard let panel else { return }
        if panel.isVisible {
            if panel.isKeyWindow {
                panel.orderOut(nil)
            } else {
                // 面板可见但不在前台（如刚被点击过）时，重新激活而不是隐藏
                show()
            }
        } else {
            show()
        }
    }

    func show() {
        guard let panel else { return }
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
