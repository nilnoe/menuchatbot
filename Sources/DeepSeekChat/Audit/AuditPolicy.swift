import Foundation

/// 审计策略（ADR-0009 D3/D8）：保留天数、容量上界、事件大小上界。
struct AuditPolicy {
    /// 默认保留 90 天（AU-7）。
    var retentionDays: Int = 90
    /// 默认容量 50MB 滚动（AU-7）。
    var maxSizeBytes: Int = 50 * 1024 * 1024
    /// 单事件大小上界 4KB（AU-6）。
    var maxEventBytes: Int = AuditRedactor.maxMetadataLength + AuditRedactor.maxMessageLength
}
