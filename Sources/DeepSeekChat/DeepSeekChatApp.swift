import AppKit

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
