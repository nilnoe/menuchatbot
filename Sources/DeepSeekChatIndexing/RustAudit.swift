import CRustCore
import Foundation

/// Rust 审计快照（ADR-0009 P2；`dc_audit_snapshot` 的 Swift 映射）。
public struct RustAuditSnapshot: Sendable, Equatable {
    /// FFI 累计调用次数。
    public var totalCalls: UInt64
    /// 未释放分配数（输出 JSON + 索引句柄；0 = 所有权配对正确，AU-14）。
    public var outstandingAllocations: Int64
    /// panic 累计次数（AU-15）。
    public var panicCount: UInt64
    /// 各错误码累计次数（AU-13）。
    public var errorCounts: [Int32: UInt64]
    /// 最近 panic 现场（消息 + 位置）。
    public var recentPanics: [String]

    public init(
        totalCalls: UInt64,
        outstandingAllocations: Int64,
        panicCount: UInt64,
        errorCounts: [Int32: UInt64],
        recentPanics: [String]
    ) {
        self.totalCalls = totalCalls
        self.outstandingAllocations = outstandingAllocations
        self.panicCount = panicCount
        self.errorCounts = errorCounts
        self.recentPanics = recentPanics
    }
}

/// Rust 审计桥接：panic hook 安装与快照采集。
///
/// unsafe 全部收敛在本文件（与 RustIndexService 同款约束）；stub 降级
/// （无 cargo 环境）时本类型为安全 no-op。
public enum RustAudit {
    /// 一次性安装 panic hook 并设置崩溃日志路径（可传 nil = 不落文件）。
    /// 进程内多次调用只安装一次（Rust 侧 Once 保证）。
    public static func install(logPath: String?) {
        guard let logPath else {
            dc_audit_init(nil)
            return
        }
        logPath.withCString { dc_audit_init($0) }
    }

    /// 拉取当前快照；stub 降级 / 解析失败返回 nil。
    public static func snapshot() -> RustAuditSnapshot? {
        var out: UnsafeMutablePointer<CChar>? = nil
        let code = dc_audit_snapshot(&out)
        defer { out.map { dc_free($0) } }
        guard code == DC_OK, let out else { return nil }
        return parse(String(cString: out))
    }

    private static func parse(_ text: String) -> RustAuditSnapshot? {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let rawCounts = (json["error_counts"] as? [String: Any]) ?? [:]
        var errorCounts: [Int32: UInt64] = [:]
        for (key, value) in rawCounts {
            guard let code = Int32(key), let number = value as? NSNumber else { continue }
            errorCounts[code] = number.uint64Value
        }
        return RustAuditSnapshot(
            totalCalls: (json["total_calls"] as? NSNumber)?.uint64Value ?? 0,
            outstandingAllocations: (json["outstanding_allocations"] as? NSNumber)?.int64Value ?? 0,
            panicCount: (json["panic_count"] as? NSNumber)?.uint64Value ?? 0,
            errorCounts: errorCounts,
            recentPanics: (json["recent_panics"] as? [String]) ?? []
        )
    }
}
