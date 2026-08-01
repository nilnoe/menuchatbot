import XCTest

@testable import DeepSeekChat

/// chat 事件解析：content / reasoning 增量、畸形形状、usage。
final class SSEParserChatEventTests: XCTestCase {
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
        for json in [
            [String: Any](), ["choices": []], ["choices": [["delta": nil]]],
            ["choices": [["foo": "bar"]]],
        ] {
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

    func testChatUsageInFinalChunk() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            [
                "choices": [],
                "usage": [
                    "prompt_tokens": 120,
                    "completion_tokens": 34,
                    "total_tokens": 154,
                    "prompt_cache_hit_tokens": 100,
                ],
            ],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(
            recorder.usages,
            [
                TokenUsage(
                    promptTokens: 120,
                    cachedTokens: 100,
                    completionTokens: 34,
                    totalTokens: 154
                )
            ]
        )
    }

    func testChatUsageMissingFieldsDefaultsToZero() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            ["choices": [], "usage": ["completion_tokens": 5]],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(
            recorder.usages,
            [TokenUsage(promptTokens: 0, cachedTokens: 0, completionTokens: 5, totalTokens: 0)]
        )
    }
}
