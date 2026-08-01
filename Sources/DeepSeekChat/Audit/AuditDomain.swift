import Foundation

/// 审计域（ADR-0009 D1）：事件按域归类，UI 可按域过滤。
enum AuditDomain: String, Codable, CaseIterable, Sendable {
    /// 配置与身份：API Key 生命周期、供应商 / 工具开关、资料库增删。
    case config
    /// 权限控制：TCC / bookmark、路径包含检查、注册表白名单、轮次上限。
    case permission
    /// 工具执行：调用、结果、耗时、沙箱门禁。
    case tool
    /// 数据与存储：迁移、DB 降级、导入导出、索引。
    case storage
    /// 内存与 FFI：错误码、panic、分配 / 泄漏。
    case ffi
    /// 网络与流：请求（脱敏）、失败 / 重试、用量。
    case network
    /// 供应链与构建：cargo audit、ABI、CI 门禁。
    case supplyChain
}

/// 严重级别：info / warning / error / critical，可比较（用于级别过滤）。
enum AuditSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case info
    case warning
    case error
    case critical

    static func < (lhs: AuditSeverity, rhs: AuditSeverity) -> Bool {
        // allCases 顺序即级别顺序；force unwrap 由 CaseIterable 保证。
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
    }
}
