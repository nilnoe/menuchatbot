import AppKit
import DeepSeekChatIndexing
import SwiftUI

/// 应用生命周期与装配（Composition Root）：
/// 创建 store / 控制器，组装主菜单、状态栏图标与主面板。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 审计组合根：先于其他 store 装配（挂点依赖 logger）。
    private lazy var auditCenter = AuditCenter(directory: AppConfiguration.appSupportDirectory)
    private lazy var sessionStore = SessionStore(audit: auditCenter.logger)
    private lazy var settingsStore = SettingsStore(audit: auditCenter.logger)
    /// 进程内工具注册表：当前仅注册 T0 计算器（其余分级随 Tier 3/4 落地）。
    private lazy var toolRegistry: InProcessToolRegistry = {
        let registry = InProcessToolRegistry()
        try? registry.register(
            CalculatorTool.definition,
            executor: CalculatorToolExecutor(
                service: RustCalculatorService()
            )
        )
        // 启动自检（ADR-0006 D3.1 / ADR-0009 B 域）：写 / 删工具以「不存在」
        // 为硬约束，自检把约束变成可审计事件。
        let suspicious = registry.suspiciousToolNames()
        if suspicious.isEmpty {
            auditCenter.logger.record(
                domain: .permission,
                category: AuditCategory.registrySelfCheckPassed,
                message: "工具注册表白名单自检通过（无写 / 删工具）"
            )
        } else {
            auditCenter.logger.record(
                domain: .permission,
                severity: .critical,
                category: AuditCategory.registryViolation,
                message: "检测到疑似写 / 删工具：\(suspicious.joined(separator: ", "))"
            )
        }
        return registry
    }()
    private lazy var streamController = ChatStreamController(
        sessionStore: sessionStore,
        settings: settingsStore,
        toolRegistry: toolRegistry,
        audit: auditCenter.logger
    )
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
            .environmentObject(auditCenter)
        // 统一系统表面风格：不叠加整窗毛玻璃。
        // 参考 ChatGPTUI / Messages 类聊天应用的惯例——系统底色 + 纯色组件，
        // 避免窗口材质与内部组件互相叠加造成风格割裂。
        let hosting = NSHostingController(rootView: root)
        panelController.install(contentViewController: hosting, settings: settingsStore)
    }
}
