import XCTest

@testable import DeepSeekChat

/// AU-8：脱敏——审计输出与导出永不包含密钥 / 全文。
final class AuditRedactionTests: XCTestCase {
    func testAPIKeyNeverSurvivesRedactionAU8() {
        let key = "sk-abcdefghijklmnop12345678"
        let text = "Authorization: Bearer \(key)"
        let redacted = AuditRedactor.stripSecrets(text)
        XCTAssertFalse(
            redacted.contains(key),
            "AU-8：审计输出不得包含 API Key（实际：\(redacted)）"
        )
        XCTAssertTrue(redacted.contains("[REDACTED:API_KEY]"))
    }

    func testTruncationBoundAU8() {
        let long = String(repeating: "内容", count: 500)
        let truncated = AuditRedactor.truncated(long)
        XCTAssertLessThanOrEqual(
            truncated.count, AuditRedactor.maxTextLength + 1,
            "AU-8：截断后长度 ≤ \(AuditRedactor.maxTextLength) + 省略号"
        )
    }

    func testSummaryKeepsDigestOnlyAU8() {
        let secret = String(repeating: "abcdefghij", count: 50) + "UNIQUE-TAIL-MARKER"
        let summary = AuditRedactor.summary(for: secret)
        XCTAssertFalse(
            summary.contains("UNIQUE-TAIL-MARKER"),
            "AU-8：超长内容不得全文出现在摘要中"
        )
        XCTAssertTrue(summary.contains("sha256:"))
        let digest = summary.components(separatedBy: "sha256:").last!
        XCTAssertEqual(digest.count, 64, "AU-8：SHA-256 摘要为 64 位十六进制")
        XCTAssertEqual(
            AuditRedactor.digest(secret), digest,
            "AU-8：同一内容摘要稳定"
        )
    }

    func testBoundedEventSizeAU8AU6() {
        let big = AuditEvent(
            domain: .tool,
            category: AuditCategory.executionStart,
            message: String(repeating: "m", count: 5000),
            metadataJSON: String(repeating: "d", count: 5000)
        )
        let bounded = AuditRedactor.bounded(big)
        XCTAssertLessThanOrEqual(
            bounded.message.count, AuditRedactor.maxMessageLength
        )
        XCTAssertLessThanOrEqual(
            bounded.metadataJSON?.count ?? 0, AuditRedactor.maxMetadataLength
        )
        XCTAssertLessThanOrEqual(
            (bounded.message.count) + (bounded.metadataJSON?.count ?? 0),
            4 * 1024,
            "AU-6：单事件 message + metadata 合计 ≤ 4KB"
        )
    }

    func testLongPathIsTruncatedInSummaryAU8() {
        let path = String(repeating: "/very/long/path/segment-", count: 20) + "secret.txt"
        let summary = AuditRedactor.summary(for: path)
        XCTAssertFalse(
            summary.contains("secret.txt"),
            "AU-8：超长路径截断后不得包含尾部原文"
        )
        XCTAssertLessThanOrEqual(
            summary.count, AuditRedactor.maxTextLength + 10 + 64,
            "AU-8：路径摘要 = 截断(≤200) + ' | sha256:' + 64 位摘要"
        )
    }
}
