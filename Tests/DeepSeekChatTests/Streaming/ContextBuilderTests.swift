import XCTest

@testable import DeepSeekChat

/// 统一上下文预算：历史截断、最后一条消息保底、token 估算（Tier 1 第二批）。
final class ContextBuilderTests: XCTestCase {
    private let builder = ContextBuilder()

    private func message(_ role: String, _ content: String) -> APIMessage {
        APIMessage(role: role, content: content)
    }

    func testEmptyHistoryStaysEmpty() {
        XCTAssertTrue(builder.buildHistory([]).isEmpty)
    }

    func testLargeBudgetKeepsAll() {
        let history = [
            message("user", "问题一"),
            message("assistant", "回答一"),
            message("user", "问题二"),
        ]
        XCTAssertEqual(builder.buildHistory(history, tokenBudget: 10_000), history)
    }

    func testTinyBudgetKeepsLastMessageOnly() {
        let history = [
            message("user", "被截断的问题"),
            message("assistant", "被截断的回答"),
            message("user", "最后的问题"),
        ]
        let result = builder.buildHistory(history, tokenBudget: 1)
        XCTAssertEqual(result, [history[2]], "预算极小时至少保留最后一条消息")
    }

    func testTruncationKeepsNewestWithinBudget() {
        let history = (0..<20).map { index in
            message(
                index.isMultiple(of: 2) ? "user" : "assistant",
                "第\(index)条：\(String(repeating: "长", count: 20))"
            )
        }
        let result = builder.buildHistory(history, tokenBudget: 100)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.last, history.last, "截断后必须保留最新消息")
        XCTAssertLessThanOrEqual(result.count, history.count, "截断只能变短")
    }

    func testCharacterTokenEstimatorCJKAndASCII() {
        let estimator = CharacterTokenEstimator()
        // 中文 1 字符 ≈ 1 token；ASCII 4 字符 ≈ 1 token。
        XCTAssertEqual(estimator.estimateTokens("中文内容"), 4)
        XCTAssertEqual(estimator.estimateTokens("abcd"), 1)
        XCTAssertEqual(estimator.estimateTokens("abcdefg"), 2)
    }
}
