import XCTest

@testable import DeepSeekChat

/// Chat Completions 流式 tool_calls 解析（T2-3a）。
final class SSEParserToolCallTests: XCTestCase {
    func testParsesToolCallDelta() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            [
                "choices": [
                    [
                        "delta": [
                            "tool_calls": [
                                [
                                    "index": 0,
                                    "id": "call_1",
                                    "function": [
                                        "name": "calculator",
                                        "arguments": #"{"expr":"1+2"}"#,
                                    ],
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.toolCallDeltas.count, 1)
        let (index, id, name, arguments) = try! XCTUnwrap(recorder.toolCallDeltas.first)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "calculator")
        XCTAssertEqual(arguments, #"{"expr":"1+2"}"#)
    }

    func testIgnoresMalformedToolCallEntries() {
        let recorder = CallbackRecorder()
        SSEParser.process(
            [
                "choices": [
                    [
                        "delta": [
                            "tool_calls": [
                                ["function": ["name": "calculator"]],  // 无 index
                                ["index": 1],  // 无 function
                            ]
                        ]
                    ]
                ]
            ],
            kind: .chat,
            callbacks: recorder.callbacks
        )
        XCTAssertTrue(recorder.toolCallDeltas.isEmpty, "畸形分片应被忽略")
    }
}
