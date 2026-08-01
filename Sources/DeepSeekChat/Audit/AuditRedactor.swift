import CryptoKit
import Foundation

/// 字段级脱敏（ADR-0009 D4，AU-8）：审计与导出永不包含密钥 / 消息全文。
enum AuditRedactor {
    /// 单条文本最长保留长度（工具参数 / 路径，AU-8）。
    static let maxTextLength = 200
    /// 事件 message 最长长度。
    static let maxMessageLength = 1024
    /// 事件 metadataJSON 最长长度（AU-6：message + metadata 合计 ≤ 4KB）。
    static let maxMetadataLength = 3072

    /// 把疑似 API Key 形态替换为占位符（防御性：正常流程不写入密钥）。
    static func stripSecrets(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)sk-[a-z0-9_-]{8,}"#,
            with: "[REDACTED:API_KEY]",
            options: .regularExpression
        )
    }

    /// 截断到 limit 字符；超长加省略号。
    static func truncated(_ text: String, limit: Int = maxTextLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// SHA-256 十六进制摘要（对账用，不可复原）。
    static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// 工具参数 / 路径摘要：截断 + 摘要（AU-8）。
    static func summary(for text: String) -> String {
        "\(truncated(stripSecrets(text))) | sha256:\(digest(text))"
    }

    /// 事件大小上界（AU-6）：message 与 metadataJSON 超限强制截断。
    static func bounded(_ event: AuditEvent) -> AuditEvent {
        var copy = event
        copy.message = truncated(copy.message, limit: maxMessageLength)
        if let metadata = copy.metadataJSON {
            copy.metadataJSON = truncated(metadata, limit: maxMetadataLength)
        }
        return copy
    }
}
