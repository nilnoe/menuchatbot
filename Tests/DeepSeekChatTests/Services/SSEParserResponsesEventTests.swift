import XCTest

@testable import DeepSeekChat

/// responses 事件解析：增量、联网搜索、终态、usage。
final class SSEParserResponsesEventTests: XCTestCase {
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
                        ["url": "not-a-url"],
                    ],
                ],
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
                    "search_results": [["url": "https://c.com"]],
                ],
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

    func testResponsesCompletedCarriesUsage() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            [
                "type": "response.completed",
                "response": [
                    "usage": [
                        "input_tokens": 88,
                        "output_tokens": 22,
                        "total_tokens": 110,
                        "input_tokens_details": ["cached_tokens": 60],
                    ]
                ],
            ],
            kind: .responses,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.doneCount, 1)
        XCTAssertEqual(
            recorder.usages,
            [
                TokenUsage(
                    promptTokens: 88,
                    cachedTokens: 60,
                    completionTokens: 22,
                    totalTokens: 110
                )
            ]
        )
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
                ],
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
}
