import AppKit
import Combine

/// 主面板窗口控制器：NSPanel 配置、默认尺寸、显示/隐藏与失去焦点收起。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel!
    private var windowSizeObservation: AnyCancellable?

    /// 安装面板并挂载内容视图控制器。
    func install(contentViewController: NSViewController, settings: SettingsStore) {
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
        // 用户显式设置过窗口大小档位 → 每次启动按档位生效（覆盖 autosave 旧 frame）；
        // 未设置过 → 沿用 0.2.x 行为：优先恢复 autosave，无记录时用默认 93% 铺满。
        if settings.hasChosenWindowSize {
            applyPresetFrame(settings.windowSizePreset)
        } else if !panel.setFrameUsingName(AppConfiguration.panelAutosaveName) {
            applyDefaultFrame()
        }
        panel.setFrameAutosaveName(AppConfiguration.panelAutosaveName)
        panel.contentViewController = contentViewController

        // 设置页变更档位时立即调整当前窗口（无需重启生效）。
        windowSizeObservation = settings.$windowSizePreset.sink { [weak self] preset in
            self?.applyPresetFrame(preset)
        }
    }

    /// 默认尺寸：主屏可见区域（去掉菜单栏 / Dock）的 93%，居中。
    private func applyDefaultFrame() {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(PanelSizing.defaultFrame(for: screen.visibleFrame), display: false)
    }

    /// 按设置档位计算居中 frame 并实时生效。
    private func applyPresetFrame(_ preset: WindowSizePreset) {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(
            PanelSizing.frame(for: screen.visibleFrame, fillRatio: preset.fillRatio),
            display: true
        )
    }

    /// 窗口默认尺寸计算（独立成纯函数，便于单测）。
    enum PanelSizing {
        /// 默认占可见区域的比值：铺满但四周留边距。
        static let defaultFillRatio: CGFloat = 0.93

        static func defaultFrame(for visible: NSRect) -> NSRect {
            frame(for: visible, fillRatio: defaultFillRatio)
        }

        /// 按占可见区域比例计算居中 frame（0.3 窗口大小档位共用）。
        static func frame(for visible: NSRect, fillRatio: CGFloat) -> NSRect {
            let width = visible.width * fillRatio
            let height = visible.height * fillRatio
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
