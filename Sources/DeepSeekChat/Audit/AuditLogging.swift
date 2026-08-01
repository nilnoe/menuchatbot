import Foundation

/// 审计记录协议（ADR-0009 D2）：所有安全事件经此入队，异步、非阻塞。
protocol AuditLogging: AnyObject {
    func record(_ event: AuditEvent)
}

/// 空实现：未装配审计时的安全默认（测试 / 降级），不产生任何副作用。
final class NullAuditLogger: AuditLogging {
    func record(_ event: AuditEvent) {}
}

extension AuditLogging {
    /// 便捷构造：域 + 级别 + 目录 + 消息 + 结构化字段。
    func record(
        domain: AuditDomain,
        severity: AuditSeverity = .info,
        category: String,
        message: String,
        sessionID: UUID? = nil,
        requestID: String? = nil,
        metadata: [String: String]? = nil
    ) {
        let metadataJSON =
            metadata.flatMap { dict in
                (try? JSONSerialization.data(withJSONObject: dict))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
        record(
            AuditEvent(
                domain: domain,
                severity: severity,
                category: category,
                message: message,
                sessionID: sessionID,
                requestID: requestID,
                metadataJSON: metadataJSON
            )
        )
    }
}
