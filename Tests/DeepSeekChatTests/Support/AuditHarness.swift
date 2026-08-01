import Foundation

@testable import DeepSeekChat

/// 审计测试脚手架：线程安全的记录 sink，供断言事件流（AU-9 等）。
/// 同时满足 AuditLogging（PathScope 等挂点直接接收）。
final class AuditRecorderSink: AuditSink, AuditLogging {
    private let lock = NSLock()
    private var storage: [AuditEvent] = []

    var events: [AuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        events.count
    }

    func record(_ event: AuditEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    /// 按域 / 目录过滤（nil = 不过滤）。
    func events(domain: AuditDomain? = nil, category: String? = nil) -> [AuditEvent] {
        events.filter { event in
            if let domain, event.domain != domain { return false }
            if let category, event.category != category { return false }
            return true
        }
    }

    func categories() -> Set<String> {
        Set(events.map(\.category))
    }

    /// 清空已记录事件（用例中途分段断言用）。
    func clear() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// 生成一个审计 logger；flushSync 前事件只入队，断言前先同步刷盘。
func makeAuditLogger(sinks: [AuditSink], batchSize: Int = 20) -> AuditLogger {
    AuditLogger(sinks: sinks, batchSize: batchSize, flushInterval: 60)
}
