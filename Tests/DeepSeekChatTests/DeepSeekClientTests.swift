import XCTest
@testable import DeepSeekChat

final class DeepSeekClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testChatCompletionsRequestAndStream() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"R1"}}]}

        data: {"choices":[{"delta":{"content":"Hello "}}]}

        data: {"choices":[{"delta":{"content":"world"}}]}

        data: [DONE]

        """
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.url?.path, "/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "enabled")
            XCTAssertEqual(json["reasoning_effort"] as? String, "high")
            let messages = json["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.first?["role"] as? String, "user")

            return (httpResponse(request, status: 200), Data(sse.utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.deltas.joined(), "Hello world")
        XCTAssertEqual(recorder.reasoning, ["R1"])
        XCTAssertEqual(recorder.doneCount, 1)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    @MainActor
    func testChatCompletionsDisabledThinking() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
            XCTAssertNil(json["reasoning_effort"])
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "hi")],
            thinking: false,
            effort: .max,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.doneCount, 1)
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
            return (httpResponse(request, status: 200), Data("data: {\"type\":\"response.completed\"}\n\n".utf8))
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
    func testUpstreamErrorReportsMessage() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = Data(#"{"error":{"message":"invalid api key","code":"invalid_request_error"}}"#.utf8)
            return (httpResponse(request, status: 401), body)
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "bad-key", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.errors, ["invalid api key"])
        XCTAssertTrue(recorder.deltas.isEmpty)
        XCTAssertEqual(recorder.doneCount, 0)
    }

    @MainActor
    func testNetworkFailureThrows() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        do {
            try await client.chatCompletions(
                model: "deepseek-v4-flash",
                messages: [APIMessage(role: "user", content: "hi")],
                thinking: true,
                effort: .high,
                callbacks: recorder.callbacks
            )
            XCTFail("应当抛出网络错误")
        } catch {
            XCTAssertTrue(recorder.errors.isEmpty)
        }
    }

    @MainActor
    func testMalformedSSELinesIgnored() async throws {
        let sse = """
        event: message
        data: {broken json

        data: {"choices":[{"delta":{"content":"ok"}}]}

        : comment

        data: [DONE]

        """
        MockURLProtocol.handler = { [self] request in
            (httpResponse(request, status: 200), Data(sse.utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [],
            thinking: true,
            effort: .high,
            callbacks: recorder.callbacks
        )

        XCTAssertEqual(recorder.deltas, ["ok"])
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
}
