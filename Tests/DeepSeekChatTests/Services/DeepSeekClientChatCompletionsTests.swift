import XCTest

@testable import DeepSeekChat

/// chatCompletions：请求装配、流式解析、自定义供应商、异常 SSE、错误上报。
final class DeepSeekClientChatCompletionsTests: XCTestCase {
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
            XCTAssertEqual(
                (json["stream_options"] as? [String: Any])?["include_usage"] as? Bool,
                true,
                "流式请求应携带 include_usage 以获取 token 用量"
            )
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
    func testChatCompletionsSystemPromptAndTemperature() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let messages = json["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.count, 2)
            XCTAssertEqual(messages?.first?["role"] as? String, "system")
            XCTAssertEqual(messages?.first?["content"] as? String, "你是一位资深 Swift 工程师")
            XCTAssertEqual(messages?.last?["role"] as? String, "user")
            XCTAssertEqual(json["temperature"] as? Double, 0.7)
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            systemPrompt: "你是一位资深 Swift 工程师",
            temperature: 0.7,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testEmptySystemPromptAndNilTemperatureOmitted() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let messages = json["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.count, 1)
            XCTAssertEqual(messages?.first?["role"] as? String, "user")
            XCTAssertNil(json["temperature"])
            XCTAssertNil(json["instructions"])
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
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
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testCustomProviderChatCompletionsOmitsDeepSeekFields() async throws {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example.com/v1/chat/completions",
                "自定义供应商应使用配置的 base_url"
            )
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "gpt-4o")
            XCTAssertNil(json["thinking"], "OpenAI 兼容供应商不应发送 DeepSeek 专属 thinking")
            XCTAssertNil(json["reasoning_effort"], "OpenAI 兼容供应商不应发送 reasoning_effort")
            XCTAssertEqual(json["temperature"] as? Double, 0.7)
            let messages = json["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.count, 2)
            XCTAssertEqual(messages?.first?["role"] as? String, "system")
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-test",
            session: makeMockURLSession()
        )
        try await client.chatCompletions(
            model: "gpt-4o",
            messages: [APIMessage(role: "user", content: "hi")],
            thinking: true,
            effort: .high,
            systemPrompt: "你是一位助手",
            temperature: 0.7,
            isCustomProvider: true,
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testUpstreamErrorReportsMessage() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = Data(
                #"{"error":{"message":"invalid api key","code":"invalid_request_error"}}"#.utf8)
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
    func testChatCompletionsFinalChunkUsageCallback() async throws {
        let sse =
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
            + "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5,\"total_tokens\":17,\"prompt_cache_hit_tokens\":8}}\n\n"
            + "data: [DONE]\n\n"
        MockURLProtocol.handler = { [self] request in
            (httpResponse(request, status: 200), Data(sse.utf8))
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

        XCTAssertEqual(recorder.deltas, ["Hello"])
        XCTAssertEqual(
            recorder.usages,
            [TokenUsage(promptTokens: 12, cachedTokens: 8, completionTokens: 5, totalTokens: 17)]
        )
    }
}
