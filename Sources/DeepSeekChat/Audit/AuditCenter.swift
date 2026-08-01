import Combine
import DeepSeekChatIndexing
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
    /// 上一次 FFI 审计快照（增量比对用，AU-13）。
    private var lastRustAudit: RustAuditSnapshot?
    private var collectionTask: Task<Void, Never>?

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
        // 安装 Rust panic hook（进程内一次性）并落崩溃日志路径（P2）。
        RustAudit.install(
            logPath: directory.appendingPathComponent("rustcore-panic.log").path)
        // 启动时执行一次保留策略（AU-7）。
        store.runRetention(days: policy.retentionDays, maxBytes: policy.maxSizeBytes)
        refreshStats()
        startPeriodicCollection()
    }

    deinit {
        collectionTask?.cancel()
    }

    /// 刷新统计与最近事件（设置页进入 / 手动刷新时调用）。
    func refreshStats() {
        collectRustAudit()
        totalCount = store.count()
        recentEvents = ring.snapshot().isEmpty ? store.recent(limit: 100) : ring.snapshot()
    }

    /// 采集 Rust 审计快照并按增量落事件（域 E：ffi.*）。
    /// stub 降级（快照为 nil）时静默跳过。
    func collectRustAudit() {
        guard let snapshot = RustAudit.snapshot() else { return }
        let previous = lastRustAudit
        lastRustAudit = snapshot

        if let previous {
            if snapshot.panicCount > previous.panicCount {
                for message in snapshot.recentPanics {
                    logger.record(
                        domain: .ffi,
                        severity: .error,
                        category: AuditCategory.ffiPanic,
                        message: AuditRedactor.truncated(
                            message, limit: AuditRedactor.maxMessageLength)
                    )
                }
            }
            for code in snapshot.errorCounts.keys.sorted() {
                let delta =
                    snapshot.errorCounts[code, default: 0]
                    - previous.errorCounts[code, default: 0]
                guard delta > 0 else { continue }
                logger.record(
                    domain: .ffi,
                    severity: .warning,
                    category: AuditCategory.ffiError,
                    message: "FFI 错误码 \(code) 新增 \(delta) 次",
                    metadata: ["code": String(code), "count": String(delta)]
                )
            }
            if snapshot.outstandingAllocations > previous.outstandingAllocations {
                logger.record(
                    domain: .ffi,
                    severity: .critical,
                    category: AuditCategory.ffiLeakDetected,
                    message: "FFI 未释放分配数增加",
                    metadata: [
                        "outstanding": String(snapshot.outstandingAllocations)
                    ]
                )
            }
            if snapshot.totalCalls > previous.totalCalls {
                logger.record(
                    domain: .ffi,
                    category: AuditCategory.ffiSnapshotCollected,
                    message: "FFI 审计快照已采集",
                    metadata: [
                        "totalCalls": String(snapshot.totalCalls),
                        "outstanding": String(snapshot.outstandingAllocations),
                    ]
                )
            }
        } else {
            logger.record(
                domain: .ffi,
                category: AuditCategory.ffiSnapshotCollected,
                message: "FFI 审计快照已初始化",
                metadata: [
                    "totalCalls": String(snapshot.totalCalls),
                    "outstanding": String(snapshot.outstandingAllocations),
                ]
            )
        }
    }

    /// 同步刷盘（测试断言与 applicationWillTerminate 使用）。
    func flushAuditLog() {
        (logger as? AuditLogger)?.flushSync()
    }

    /// 导出全部事件（脱敏由 AuditRedactor 保证，AU-8 / AU-20）。
    func exportJSON() throws -> Data {
        try store.exportJSON()
    }

    private func startPeriodicCollection() {
        collectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.collectRustAudit()
            }
        }
    }
}
