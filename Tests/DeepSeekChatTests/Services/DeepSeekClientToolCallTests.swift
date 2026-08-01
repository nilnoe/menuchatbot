import XCTest

@testable import DeepSeekChat

/// Chat Completions 工具调用：请求体 tools 装配、流式 tool_calls 解析回传、
/// 工具消息历史序列化（T2-3a）。
final class DeepSeekClientToolCallTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private let calculatorTool = ToolDefinition(
        name: "calculator",
        description: "计算数学表达式",
        parametersJSONSchema:
            #"{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]}"#,
        tier: .calculator
    )

    @MainActor
    func testChatCompletionsSendsToolsAndToolChoice() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(json["tool_choice"] as? String, "auto")
            XCTAssertEqual(tools.count, 1)
            XCTAssertEqual(tools[0]["type"] as? String, "function")
            let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "calculator")
            let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["type"] as? String, "object")
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "计算 1+2")],
            thinking: false,
            effort: .high,
            tools: [calculatorTool],
            callbacks: recorder.callbacks
        )
        XCTAssertEqual(recorder.doneCount, 1)
    }

    @MainActor
    func testStreamingToolCallsAssembledAndReported() async throws {
        let sse = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"calculator","arguments":"{\\"expr\\":\\"1 +"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" 2\\"}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
        MockURLProtocol.handler = { [self] request in
            (httpResponse(request, status: 200), Data(sse.utf8))
        }

        let recorder = CallbackRecorder()
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "计算")],
            thinking: false,
            effort: .high,
            tools: [calculatorTool],
            callbacks: recorder.callbacks
        )

        let finished = try XCTUnwrap(recorder.finishedToolCalls.first)
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished[0].id, "call_1")
        XCTAssertEqual(finished[0].function.name, "calculator")
        XCTAssertEqual(finished[0].function.arguments, #"{"expr":"1 + 2"}"#)
    }

    @MainActor
    func testToolMessagesSerializedInRequestBody() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 3)

            let assistant = try XCTUnwrap(messages[1])
            XCTAssertEqual(assistant["role"] as? String, "assistant")
            let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
            XCTAssertEqual(toolCalls[0]["id"] as? String, "call_1")
            XCTAssertEqual(
                (toolCalls[0]["function"] as? [String: Any])?["name"] as? String,
                "calculator"
            )

            let tool = try XCTUnwrap(messages[2])
            XCTAssertEqual(tool["role"] as? String, "tool")
            XCTAssertEqual(tool["tool_call_id"] as? String, "call_1")
            XCTAssertEqual(tool["name"] as? String, "calculator")
            XCTAssertEqual(tool["content"] as? String, "结果：3")
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }

        let history: [APIMessage] = [
            APIMessage(role: "user", content: "计算 1+2"),
            APIMessage(
                role: "assistant",
                content: "",
                toolCalls: [
                    APIToolCall(
                        id: "call_1",
                        function: APIFunctionCall(name: "calculator", arguments: #"{"expr":"1+2"}"#)
                    )
                ]
            ),
            APIMessage(
                role: "tool",
                content: "结果：3",
                toolCallID: "call_1",
                name: "calculator"
            ),
        ]
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: history,
            thinking: false,
            effort: .high,
            callbacks: CallbackRecorder().callbacks
        )
    }

    @MainActor
    func testNoToolsWhenListEmpty() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertNil(json["tools"])
            XCTAssertNil(json["tool_choice"])
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "hi")],
            thinking: false,
            effort: .high,
            callbacks: CallbackRecorder().callbacks
        )
    }
}
