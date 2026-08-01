import Foundation

/// 审计事件（ADR-0009 D2）：追加式记录，AuditStore 不提供 update / delete。
struct AuditEvent: Codable, Equatable, Sendable {
    /// 数据库自增主键（单调递增，AU-2）；未落库时为 nil。
    var id: Int64?
    /// 事件唯一标识（导出 / UI 引用用）。
    var eventID: UUID
    var timestamp: Date
    var domain: AuditDomain
    var severity: AuditSeverity
    /// 事件目录中的稳定标识，如 "permission.denied"（AuditCategory）。
    var category: String
    /// 已脱敏的可读描述（AU-8：不包含密钥 / 全文）。
    var message: String
    var sessionID: UUID?
    /// 每次 send 生成，贯穿工具轮次与流式（AU-9 关联）。
    var requestID: String?
    /// 结构化字段（工具名 / 耗时 / 错误码 / 路径摘要等），受大小上限约束。
    var metadataJSON: String?

    init(
        id: Int64? = nil,
        eventID: UUID = UUID(),
        timestamp: Date = Date(),
        domain: AuditDomain,
        severity: AuditSeverity = .info,
        category: String,
        message: String,
        sessionID: UUID? = nil,
        requestID: String? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.timestamp = timestamp
        self.domain = domain
        self.severity = severity
        self.category = category
        self.message = message
        self.sessionID = sessionID
        self.requestID = requestID
        self.metadataJSON = metadataJSON
    }
}
