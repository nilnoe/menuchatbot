import Foundation

/// 审计记录器（ADR-0009 D2/D8）：record 同步入队、批量异步落 sink，
/// 主线程开销最小（AU-3）；sink 故障不阻塞业务（AU-4）。
final class AuditLogger: AuditLogging {
    private let lock = NSLock()
    private var pending: [AuditEvent] = []
    private let sinks: [AuditSink]
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private let flushQueue = DispatchQueue(
        label: "com.deepseek.chat.audit.flush", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(
        sinks: [AuditSink],
        batchSize: Int = 20,
        flushInterval: TimeInterval = 0.5
    ) {
        self.sinks = sinks
        self.batchSize = max(1, batchSize)
        self.flushInterval = max(0.05, flushInterval)
        startTimer()
    }

    deinit {
        timer?.cancel()
    }

    func record(_ event: AuditEvent) {
        let bounded = AuditRedactor.bounded(event)
        lock.lock()
        pending.append(bounded)
        let shouldFlush = pending.count >= batchSize
        lock.unlock()
        if shouldFlush {
            flushAsync()
        }
    }

    /// 同步刷盘：应用退出（applicationWillTerminate）与测试断言用。
    func flushSync() {
        let batch = takeBatch()
        deliver(batch)
    }

    /// 当前待刷事件数（测试可观测）。
    func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // MARK: - 内部

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushAsync()
        }
        timer.resume()
        self.timer = timer
    }

    private func flushAsync() {
        let batch = takeBatch()
        guard !batch.isEmpty else { return }
        flushQueue.async { [sinks] in
            for sink in sinks {
                for event in batch {
                    sink.record(event)
                }
            }
        }
    }

    private func takeBatch() -> [AuditEvent] {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return []
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        return batch
    }

    private func deliver(_ batch: [AuditEvent]) {
        guard !batch.isEmpty else { return }
        for sink in sinks {
            for event in batch {
                sink.record(event)
            }
        }
    }
}
