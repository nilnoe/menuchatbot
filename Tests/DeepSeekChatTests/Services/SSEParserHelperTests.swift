import XCTest

@testable import DeepSeekChat

/// 辅助解析：`extractSources` 与 `parseError`。
final class SSEParserHelperTests: XCTestCase {
    // MARK: - extractSources

    func testExtractSourcesNestedAndDeduplicated() {
        let json: [String: Any] = [
            "response": [
                "output": [
                    [
                        "web_search_call": [
                            "search_results": [
                                ["title": "X", "url": "https://x.com"],
                                ["url": "https://x.com"],
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let sources = SSEParser.extractSources(json)
        XCTAssertEqual(sources.first?.url, "https://x.com")
        XCTAssertEqual(sources.first?.title, "X")
        XCTAssertEqual(sources.count, 1)
    }

    func testExtractSourcesRejectsInvalidURLs() {
        let sources = SSEParser.extractSources([
            "results": [
                ["url": "ftp://x.com"],
                ["url": ""],
                ["url": 42],
                ["url": "https://ok.com"],
            ]
        ])
        XCTAssertEqual(sources.map(\.url), ["https://ok.com"])
    }

    func testExtractSourcesEmptyForScalars() {
        XCTAssertTrue(SSEParser.extractSources("plain").isEmpty)
        XCTAssertTrue(SSEParser.extractSources(42).isEmpty)
        XCTAssertTrue(SSEParser.extractSources([:]).isEmpty)
    }

    // MARK: - parseError

    func testParseErrorExtractsMessage() {
        XCTAssertEqual(
            SSEParser.parseError(#"{"error":{"message":"Authentication Fails","type":"auth"}}"#),
            "Authentication Fails"
        )
    }

    func testParseErrorFallsBackToText() {
        XCTAssertEqual(SSEParser.parseError("boom"), "boom")
    }

    func testParseErrorEmptyText() {
        XCTAssertEqual(SSEParser.parseError(""), "请求失败")
    }

    func testParseErrorTruncatesLongText() {
        let long = String(repeating: "x", count: 1000)
        let parsed = SSEParser.parseError(long)
        XCTAssertEqual(parsed.count, 500)
    }

    func testParseErrorMalformedJSONFallsBack() {
        XCTAssertEqual(SSEParser.parseError("not json {"), "not json {")
    }
}
