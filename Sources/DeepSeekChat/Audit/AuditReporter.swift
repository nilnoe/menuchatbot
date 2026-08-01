import Foundation

/// 审计报告器（ADR-0009 D1）：查询 + 导出，供设置页审计查看器使用。
struct AuditReporter {
    let store: AuditStore

    func count() -> Int {
        store.count()
    }

    func recent(
        limit: Int = 100,
        domain: AuditDomain? = nil,
        severity: AuditSeverity? = nil
    ) -> [AuditEvent] {
        store.recent(limit: limit, domain: domain, severity: severity)
    }

    func exportJSON() throws -> Data {
        try store.exportJSON()
    }
}
