import XCTest
@testable import DeepSeekChat

final class SSEParserTests: XCTestCase {
    // MARK: - payload(fromLine:)

    func testPayloadFromDataLine() {
        XCTAssertEqual(
            SSEParser.payload(fromLine: "data: {\"a\":1}"),
            "{\"a\":1}"
        )
    }

    func testPayloadTrimsWhitespace() {
        XCTAssertEqual(SSEParser.payload(fromLine: "  data:  hello  "), "hello")
    }

    func testPayloadForDone() {
        XCTAssertEqual(SSEParser.payload(fromLine: "data: [DONE]"), "[DONE]")
    }

    func testPayloadForEmptyData() {
        XCTAssertEqual(SSEParser.payload(fromLine: "data:"), "")
    }

    func testPayloadRejectsNonDataLines() {
        XCTAssertNil(SSEParser.payload(fromLine: "event: message"))
        XCTAssertNil(SSEParser.payload(fromLine: ""))
        XCTAssertNil(SSEParser.payload(fromLine: ": comment"))
    }

    // MARK: - chat 事件

    func testChatDeltaContent() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["choices": [["delta": ["content": "hi"]]]],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.deltas, ["hi"])
        XCTAssertTrue(recorder.reasoning.isEmpty)
        XCTAssertEqual(recorder.doneCount, 0)
    }

    func testChatDeltaReasoning() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["choices": [["delta": ["reasoning_content": "think"]]]],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.reasoning, ["think"])
        XCTAssertTrue(recorder.deltas.isEmpty)
    }

    func testChatDeltaBothContentAndReasoning() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["choices": [["delta": ["content": "c", "reasoning_content": "r"]]]],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.deltas, ["c"])
        XCTAssertEqual(recorder.reasoning, ["r"])
    }

    func testChatDeltaEmptyStringsIgnored() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["choices": [["delta": ["content": "", "reasoning_content": ""]]]],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertTrue(recorder.deltas.isEmpty)
        XCTAssertTrue(recorder.reasoning.isEmpty)
    }

    func testChatMalformedShapesDoNotCrash() {
        let recorder = CallbackRecorder()
        for json in [[String: Any](), ["choices": []], ["choices": [["delta": nil]]], ["choices": [["foo": "bar"]]]] {
            SSEParser.process(json, kind: .chat, callbacks: recorder.callbacks)
        }
        XCTAssertTrue(recorder.deltas.isEmpty)
        XCTAssertTrue(recorder.reasoning.isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testChatEventNeverTerminal() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            ["choices": [["delta": ["content": "x"]]]],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertFalse(finished)
    }

    // MARK: - responses 事件

    func testResponsesOutputDelta() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["type": "response.output_text.delta", "delta": "hello"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.deltas, ["hello"])
    }

    func testResponsesReasoningDelta() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["type": "response.reasoning_text.delta", "delta": "reason"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.reasoning, ["reason"])
    }

    func testResponsesWebSearchSearching() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["type": "response.web_search_call.in_progress"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        SSEParser.process(
            ["type": "response.web_search_call.searching"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.searchingCount, 2)
        XCTAssertTrue(recorder.sources.isEmpty)
    }

    func testResponsesWebSearchCompletedExtractsSources() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            [
                "type": "response.web_search_call.completed",
                "item": [
                    "type": "web_search_call",
                    "search_results": [
                        ["title": "A", "url": "https://a.com"],
                        ["title": "A", "url": "https://a.com"],
                        ["url": "https://b.com"],
                        ["url": "not-a-url"]
                    ]
                ]
            ],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.sources.count, 1)
        XCTAssertEqual(recorder.sources.first?.map(\.url), ["https://a.com", "https://b.com"])
    }

    func testResponsesOutputItemDoneWithWebSearch() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            [
                "type": "response.output_item.done",
                "item": [
                    "type": "web_search_call",
                    "search_results": [["url": "https://c.com"]]
                ]
            ],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.sources.first?.map(\.url), ["https://c.com"])
    }

    func testResponsesCompletedIsTerminal() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            ["type": "response.completed"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertTrue(finished)
        XCTAssertEqual(recorder.doneCount, 1)
    }

    func testResponsesIncompleteIsTerminal() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            ["type": "response.incomplete"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertTrue(finished)
        XCTAssertEqual(recorder.doneCount, 1)
    }

    func testResponsesFailedIsTerminalAndReportsMessage() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            [
                "type": "response.failed",
                "response": [
                    "error": ["message": "上游出错"]
                ]
            ],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertTrue(finished)
        XCTAssertEqual(recorder.errors, ["上游出错"])
    }

    func testResponsesFailedWithoutMessageUsesFallback() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            ["type": "response.failed"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertTrue(finished)
        XCTAssertEqual(recorder.errors, ["生成失败（response.failed）"])
    }

    func testResponsesUnknownTypeIgnored() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            ["type": "response.created", "foo": "bar"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertFalse(finished)
        XCTAssertTrue(recorder.deltas.isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(recorder.doneCount, 0)
    }

    func testResponsesMissingTypeIgnored() {
        let recorder = CallbackRecorder()
        let finished = SSEParser.process(
            ["delta": "x"],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertFalse(finished)
    }

    // MARK: - extractSources

    func testExtractSourcesNestedAndDeduplicated() {
        let json: [String: Any] = [
            "response": [
                "output": [
                    ["web_search_call": ["search_results": [
                        ["title": "X", "url": "https://x.com"],
                        ["url": "https://x.com"]
                    ]]]
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
                ["url": "https://ok.com"]
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
