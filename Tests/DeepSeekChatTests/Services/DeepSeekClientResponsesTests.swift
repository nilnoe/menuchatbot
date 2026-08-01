import XCTest

@testable import DeepSeekChat

/// responses：联网搜索、reasoning 开关、instructions/temperature、异常收尾、用量回调。
final class DeepSeekClientResponsesTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testResponsesRequestWithWebSearch() async throws {
        let sse = """
            data: {"type":"response.web_search_call.in_progress"}

            data: {"type":"response.web_search_call.searching"}

            data: {"type":"response.web_search_call.completed","item":{"type":"web_search_call","search_results":[{"title":"X","url":"https://x.com"}]}}

            data: {"type":"response.reasoning_text.delta","delta":"reason"}

            data: {"type":"response.output_text.delta","delta":"answer"}

            data: {"type":"response.completed"}

            """
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.url?.path, "/responses")
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
            XCTAssertEqual(
                (json["tools"] as? [[String: Any]])?.first?["type"] as? String,
                "web_search"
            )
            return (httpResponse(request, status: 200), Data(sse.utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.responses(
            model: "deepseek-v4-flash",
            input: [APIMessage(role: "user", content: "今日新闻")],
            thinking: true,
            effort: .high,
            webSearch: true,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.searchingCount, 2)
        XCTAssertEqual(recorder.sources.first?.map(\.url), ["https://x.com"])
        XCTAssertEqual(recorder.reasoning, ["reason"])
        XCTAssertEqual(recorder.deltas, ["answer"])
        // completed 事件触发 onDone，流结束不重复触发
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testResponsesReasoningNoneWhenThinkingDisabled() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "none")
            XCTAssertNil(json["tools"])
            return (
                httpResponse(request, status: 200),
                Data("data: {\"type\":\"response.completed\"}\n\n".utf8)
            )
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.responses(
            model: "deepseek-v4-flash",
            input: [APIMessage(role: "user", content: "hi")],
            thinking: false,
            effort: .low,
            webSearch: false,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testResponsesInstructionsAndTemperature() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["instructions"] as? String, "回答使用简体中文")
            XCTAssertEqual(json["temperature"] as? Double, 0.3)
            return (
                httpResponse(request, status: 200),
                Data("data: {\"type\":\"response.completed\"}\n\n".utf8)
            )
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.responses(
            model: "deepseek-v4-flash",
            input: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            webSearch: false,
            systemPrompt: "回答使用简体中文",
            temperature: 0.3,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testStreamEndingWithoutTerminalStillFinishes() async throws {
        let sse = """
            data: {"type":"response.output_text.delta","delta":"partial"}

            """
        MockURLProtocol.handler = { [self] request in
            (httpResponse(request, status: 200), Data(sse.utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.responses(
            model: "deepseek-v4-flash",
            input: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            webSearch: false,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.deltas, ["partial"])
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testResponsesCompletedUsageCallback() async throws {
        let sse =
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":30,\"output_tokens\":7,\"total_tokens\":37,\"input_tokens_details\":{\"cached_tokens\":20}}}}\n\n"
        MockURLProtocol.handler = { [self] request in
            (httpResponse(request, status: 200), Data(sse.utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.responses(
            model: "deepseek-v4-flash",
            input: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            webSearch: false,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.deltas, ["answer"])
        XCTAssertEqual(
            recorder.usages,
            [TokenUsage(promptTokens: 30, cachedTokens: 20, completionTokens: 7, totalTokens: 37)]
        )
    }
}
