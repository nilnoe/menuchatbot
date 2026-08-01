import Foundation

/// 审计 sink：AuditLogger 的落点。
protocol AuditSink: AnyObject {
    func record(_ event: AuditEvent)
}

/// os_log sink：实时可查（Console.app / log stream）。
final class OSLogAuditSink: AuditSink {
    func record(_ event: AuditEvent) {
        switch event.severity {
        case .critical, .error:
            AppLog.audit.error(
                "\(event.category, privacy: .public): \(event.message, privacy: .public)"
            )
        case .warning:
            AppLog.audit.warning(
                "\(event.category, privacy: .public): \(event.message, privacy: .public)"
            )
        case .info:
            AppLog.audit.info(
                "\(event.category, privacy: .public): \(event.message, privacy: .public)"
            )
        }
    }
}

/// 数据库 sink：追加式持久化（audit.sqlite，ADR-0009 D3）。
final class DatabaseAuditSink: AuditSink {
    private let store: AuditStore

    init(store: AuditStore) {
        self.store = store
    }

    func record(_ event: AuditEvent) {
        store.insert(event)
    }
}

/// 内存环形缓冲 sink：最近 N 条供 UI 实时展示。
final class MemoryRingSink: AuditSink {
    private let lock = NSLock()
    private var buffer: [AuditEvent] = []
    let capacity: Int
    /// 缓冲更新回调（可能在其他线程；由持有者负责派发到主线程）。
    var onUpdate: (([AuditEvent]) -> Void)?

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    func record(_ event: AuditEvent) {
        lock.lock()
        buffer.append(event)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        let snapshot = buffer
        lock.unlock()
        onUpdate?(snapshot)
    }

    func snapshot() -> [AuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
