import Combine
import Foundation

/// 审计组合根（AppDelegate 装配）：存储 + 记录器 + 报告器，作为环境对象注入 UI。
final class AuditCenter: ObservableObject {
    @Published private(set) var recentEvents: [AuditEvent] = []
    @Published private(set) var totalCount: Int = 0

    let store: AuditStore
    let policy: AuditPolicy
    let logger: AuditLogging
    let reporter: AuditReporter

    private let ring: MemoryRingSink

    /// 打开独立审计库；失败时降级为内存库（AU-4：审计故障不阻塞业务）。
    init(directory: URL, policy: AuditPolicy = AuditPolicy()) {
        self.policy = policy
        if let store = try? AuditStore(directory: directory) {
            self.store = store
        } else {
            AppLog.audit.error("打开审计库失败，改用内存库（审计不落盘）")
            self.store = AuditStore.inMemory()
        }
        reporter = AuditReporter(store: self.store)
        ring = MemoryRingSink(capacity: 100)
        logger = AuditLogger(
            sinks: [ring, DatabaseAuditSink(store: self.store), OSLogAuditSink()])
        ring.onUpdate = { [weak self] events in
            DispatchQueue.main.async {
                self?.recentEvents = events
            }
        }
        // 启动时执行一次保留策略（AU-7）。
        store.runRetention(days: policy.retentionDays, maxBytes: policy.maxSizeBytes)
        refreshStats()
    }

    /// 刷新统计与最近事件（设置页进入 / 手动刷新时调用）。
    func refreshStats() {
        totalCount = store.count()
        recentEvents = ring.snapshot().isEmpty ? store.recent(limit: 100) : ring.snapshot()
    }

    /// 导出全部事件（脱敏由 AuditRedactor 保证，AU-8 / AU-20）。
    func exportJSON() throws -> Data {
        try store.exportJSON()
    }
}
