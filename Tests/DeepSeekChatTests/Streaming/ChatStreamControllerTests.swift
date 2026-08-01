import XCTest

@testable import DeepSeekChat

/// ChatStreamController 生命周期单测：发送 / 复用会话 / 重试 / 停止 / 错误 / 竞态。
@MainActor
final class ChatStreamControllerTests: XCTestCase {
    private var tempDir: URL!
    private var store: SessionStore!
    private var settings: SettingsStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStreamController-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SessionStore(storageDirectory: tempDir)

        let keychain = MockKeychain()
        keychain.storage["apiKey"] = "test-key"
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: "ChatStreamController-\(UUID().uuidString)")!,
            keychain: keychain,
            keychainSaveDelay: .zero
        )
    }

    override func tearDownWithError() throws {
        DelayedStreamingURLProtocol.handler = nil
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 构造控制器，网络走可控时序的延迟流式协议。
    private func makeController(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, [String], TimeInterval),
        toolRegistry: ToolRegistry? = nil,
        maxToolRounds: Int = AppConfiguration.defaultMaxToolRounds
    ) -> ChatStreamController {
        DelayedStreamingURLProtocol.handler = handler
        return ChatStreamController(
            sessionStore: store,
            settings: settings,
            toolRegistry: toolRegistry,
            maxToolRounds: maxToolRounds,
            makeClient: { _, baseURL in
                DeepSeekClient(
                    baseURL: baseURL, apiKey: "test-key",
                    session: self.makeDelayedStreamingURLSession())
            }
        )
    }

    private func waitFor(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("等待条件超时")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - 发送

    func testSendCreatesSessionAndStreamsToCompletion() async throws {
        let controller = makeController { [self] request in
            XCTAssertEqual(request.url?.path, "/chat/completions")
            let chunks = [
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"推理\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n",
                "data: [DONE]\n\n",
            ]
            return (httpResponse(request, status: 200), chunks, 0.05)
        }

        let created = controller.send("你好世界", selectedSessionID: nil)
        let sessionID = try XCTUnwrap(created, "自动创建会话应返回新 ID")
        XCTAssertEqual(controller.streamingSessionID, sessionID)
        XCTAssertNotNil(controller.streamingState)

        try await waitFor { controller.streamingSessionID == nil }

        let session = try XCTUnwrap(store.session(id: sessionID))
        XCTAssertEqual(session.title, "你好世界", "空会话发送后应以消息前 30 字命名")
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages.first?.role, .user)
        XCTAssertEqual(session.messages.last?.role, .assistant)
        XCTAssertEqual(session.messages.last?.content, "你好")
        XCTAssertEqual(session.messages.last?.reasoning, "推理")
    }

    func testSendUsesSelectedSessionInsteadOfCreatingNew() async throws {
        let session = store.createSession(title: "已有会话")
        let controller = makeController { [self] request in
            (
                httpResponse(request, status: 200),
                ["data: {\"choices\":[{\"delta\":{\"content\":\"答\"}}]}\n\n", "data: [DONE]\n\n"],
                0.02
            )
        }

        let used = controller.send("问题", selectedSessionID: session.id)
        XCTAssertEqual(used, session.id)
        XCTAssertEqual(store.sessions.count, 1, "选中已有会话时不应新建")
        try await waitFor { controller.streamingSessionID == nil }
        XCTAssertEqual(store.session(id: session.id)?.messages.last?.content, "答")
    }

    // MARK: - 自定义供应商

    func testCustomProviderRoutesToCustomBaseURLWithoutDeepSeekFields() async throws {
        settings.customProviderEnabled = true
        settings.customBaseURL = "https://api.example.com/v1"
        settings.customModels = [CustomModel(id: "gpt-4o", name: "GPT-4o")]
        settings.model = "gpt-4o"
        settings.webSearch = true

        let session = store.createSession(title: "自定义供应商")
        let controller = makeController { [self] request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example.com/v1/chat/completions",
                "自定义供应商应请求配置的 base_url 且走 Chat Completions"
            )
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "gpt-4o")
            XCTAssertNil(json["thinking"])
            XCTAssertNil(json["reasoning_effort"])
            XCTAssertNil(json["tools"], "自定义模型不支持联网搜索，不应发 Responses 工具")
            return (
                httpResponse(request, status: 200),
                [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"自定义回复\"}}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                0.02
            )
        }

        controller.beginAssistantReply(sessionID: session.id)
        try await waitFor { controller.streamingSessionID == nil }

        let last = try XCTUnwrap(store.session(id: session.id)?.messages.last)
        XCTAssertEqual(last.content, "自定义回复")
        XCTAssertFalse(last.isSearching, "自定义模型不触发搜索状态")
    }

    // MARK: - Token 用量

    func testStreamUsagePersistedToMessage() async throws {
        let session = store.createSession(title: "用量会话")
        let controller = makeController { [self] request in
            (
                httpResponse(request, status: 200),
                [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"答\"}}]}\n\n",
                    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":7,\"total_tokens\":49,\"prompt_cache_hit_tokens\":20}}\n\n",
                    "data: [DONE]\n\n",
                ],
                0.02
            )
        }

        controller.beginAssistantReply(sessionID: session.id)
        try await waitFor { controller.streamingSessionID == nil }

        let last = try XCTUnwrap(store.session(id: session.id)?.messages.last)
        XCTAssertEqual(
            last.usage,
            TokenUsage(promptTokens: 42, cachedTokens: 20, completionTokens: 7, totalTokens: 49)
        )
    }

    // MARK: - 重试

    func testRetryRemovesErrorMessageAndRestarts() async throws {
        let session = store.createSession(title: "重试会话")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "问题"))
        store.appendMessage(
            sessionID: session.id,
            ChatMessage(role: .assistant, content: "生成失败", isError: true)
        )

        let controller = makeController { [self] request in
            (
                httpResponse(request, status: 200),
                [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"重试成功\"}}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                0.02
            )
        }

        controller.retryLastExchange(in: session.id)
        XCTAssertNotNil(controller.streamingState, "重试应立即启动新一轮流式")
        try await waitFor { controller.streamingSessionID == nil }

        let messages = try XCTUnwrap(store.session(id: session.id)).messages
        XCTAssertEqual(messages.count, 2, "错误回复应被删除，只保留用户消息 + 新回复")
        XCTAssertFalse(messages.last?.isError ?? true)
        XCTAssertEqual(messages.last?.content, "重试成功")
    }

    // MARK: - 停止

    func testStopClearsStreamingStateImmediately() async throws {
        let session = store.createSession(title: "停止会话")
        // 流式不结束（只有分片没有 [DONE]），确保停止前一直处于流式。
        let controller = makeController { [self] request in
            (
                httpResponse(request, status: 200),
                [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"正在生成\"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\"仍在生成\"}}]}\n\n",
                ],
                5.0
            )
        }

        controller.beginAssistantReply(sessionID: session.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(controller.streamingState)

        controller.stop()
        XCTAssertNil(controller.streamingSessionID)
        XCTAssertNil(controller.streamingState)

        // 旧任务收尾不应崩溃，也不应复活流式状态。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(controller.streamingSessionID)
    }

    // MARK: - 错误

    func testNetworkErrorMarksMessageAsError() async throws {
        let session = store.createSession(title: "错误会话")
        let controller = makeController { [self] request in
            let body = #"{"error":{"message":"invalid api key"}}"#
            return (httpResponse(request, status: 401), [body], 0)
        }

        controller.beginAssistantReply(sessionID: session.id)
        try await waitFor {
            store.session(id: session.id)?.messages.last?.isError == true
        }

        let last = try XCTUnwrap(store.session(id: session.id)?.messages.last)
        XCTAssertTrue(last.isError)
        XCTAssertEqual(last.content, "invalid api key")
    }

    // MARK: - 竞态（旧任务延迟收尾不覆盖新一轮流式）

    func testStaleTaskCleanupDoesNotClearNewStream() async throws {
        let session = store.createSession(title: "竞态会话")
        // 任务 A：第一片立即到、[DONE] 0.6s 后才到，模拟长流。
        let controller = makeController { [self] request in
            (
                httpResponse(request, status: 200),
                [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                0.6
            )
        }

        controller.beginAssistantReply(sessionID: session.id)
        try await Task.sleep(for: .milliseconds(100))
        controller.stop()

        // 任务 B：0.5s 才 [DONE]，保证旧任务收尾时 B 仍在流式。
        DelayedStreamingURLProtocol.handler = { [self] request in
            (
                httpResponse(request, status: 200),
                [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                0.5
            )
        }
        controller.beginAssistantReply(sessionID: session.id)
        let secondState = controller.streamingState

        // 旧任务收尾（取消传播约 100ms 内完成）之后、B 完成（约 500ms）之前：
        // 流式状态必须仍属于 B——历史竞态缺陷在此断言下会失败。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.streamingSessionID, session.id, "旧任务收尾不应清掉新一轮流式状态")
        XCTAssertTrue(controller.streamingState === secondState)

        try await waitFor { controller.streamingSessionID == nil }
        XCTAssertEqual(store.session(id: session.id)?.messages.last?.content, "B")
    }

    // MARK: - 工具调用循环（T2-3）

    /// 记录式计算器执行器（测试双）。
    private final class RecordingToolExecutor: ToolExecuting, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var completedCount = 0
        private(set) var arguments: [String] = []
        var delay: TimeInterval = 0

        func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
            callCount += 1
            arguments.append(request.argumentsJSON)
            if delay > 0 {
                // 取消后仍返回结果：验证 stop 后 in-flight 调用收尾、结果照常落库。
                try? await Task.sleep(for: .milliseconds(delay * 1000))
            }
            let result = ToolExecutionResult(
                toolName: request.toolName,
                success: true,
                output: "3",
                duration: 0
            )
            completedCount += 1
            return result
        }
    }

    private func makeToolRegistry(executor: ToolExecuting) throws -> InProcessToolRegistry {
        let registry = InProcessToolRegistry()
        try registry.register(
            ToolDefinition(
                name: "calculator",
                description: "计算数学表达式",
                parametersJSONSchema: #"{"type":"object"}"#,
                tier: .calculator
            ),
            executor: executor
        )
        return registry
    }

    private func toolCallChunks(
        id: String = "call_1",
        arguments: String = #"{"expr":"1+2"}"#
    ) -> [String] {
        let escaped =
            arguments
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let delta =
            "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"\(id)\",\"function\":{\"name\":\"calculator\",\"arguments\":\"\(escaped)\"}}]}}]}"
        return [
            "data: \(delta)\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n",
        ]
    }

    func testToolCallLoopExecutesToolAndContinuesToFinalAnswer() async throws {
        let executor = RecordingToolExecutor()
        let registry = try makeToolRegistry(executor: executor)
        var requestCount = 0

        let controller = makeController(
            { [self] request in
                requestCount += 1
                if requestCount == 1 {
                    return (httpResponse(request, status: 200), toolCallChunks(), 0.02)
                }
                // 第二轮：验证历史中已包含 tool 消息。
                let body = try httpBody(of: request)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                let toolMessage = messages.last(where: { $0["role"] as? String == "tool" })
                XCTAssertNotNil(toolMessage, "第二轮请求应携带 tool 结果消息")
                XCTAssertEqual(toolMessage?["tool_call_id"] as? String, "call_1")
                XCTAssertEqual(toolMessage?["content"] as? String, "结果：3")
                return (
                    httpResponse(request, status: 200),
                    [
                        "data: {\"choices\":[{\"delta\":{\"content\":\"答案是 3\"}}]}\n\n",
                        "data: [DONE]\n\n",
                    ],
                    0.02
                )
            }, toolRegistry: registry)

        let session = store.createSession(title: "工具会话")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "计算 1+2"))
        controller.beginAssistantReply(sessionID: session.id)
        try await waitFor { controller.streamingSessionID == nil }

        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(executor.arguments, [#"{"expr":"1+2"}"#])

        let messages = try XCTUnwrap(store.session(id: session.id)?.messages)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "答案是 3")
        let toolMessage = try XCTUnwrap(messages.last(where: { $0.role == .tool }))
        XCTAssertEqual(toolMessage.toolName, "calculator")
        XCTAssertEqual(toolMessage.toolCallID, "call_1")
        XCTAssertEqual(toolMessage.content, "结果：3")

        let assistantWithCalls = try XCTUnwrap(
            messages.first(where: { !($0.toolCalls?.isEmpty ?? true) })
        )
        XCTAssertEqual(assistantWithCalls.toolCalls?.first?.name, "calculator")
        XCTAssertEqual(assistantWithCalls.toolCalls?.first?.arguments, #"{"expr":"1+2"}"#)
    }

    func testToolCallLoopRespectsMaxRounds() async throws {
        let executor = RecordingToolExecutor()
        let registry = try makeToolRegistry(executor: executor)
        var requestCount = 0

        let controller = makeController(
            { [self] request in
                requestCount += 1
                if requestCount <= 4 {
                    return (
                        httpResponse(request, status: 200),
                        toolCallChunks(id: "call_\(requestCount)"), 0.02
                    )
                }
                return (
                    httpResponse(request, status: 200),
                    [
                        "data: {\"choices\":[{\"delta\":{\"content\":\"最终答案\"}}]}\n\n",
                        "data: [DONE]\n\n",
                    ],
                    0.02
                )
            }, toolRegistry: registry, maxToolRounds: 3)

        let session = store.createSession(title: "轮次上限")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "问题"))
        controller.beginAssistantReply(sessionID: session.id)
        try await waitFor { controller.streamingSessionID == nil }

        XCTAssertEqual(executor.callCount, 3, "超过上限后不应继续执行工具")
        let messages = try XCTUnwrap(store.session(id: session.id)?.messages)
        XCTAssertTrue(
            messages.contains { $0.role == .tool && $0.content.contains("轮次已达上限") },
            "应写入轮次上限提示"
        )
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "最终答案")
    }

    func testStopPreventsFurtherToolExecution() async throws {
        let executor = RecordingToolExecutor()
        executor.delay = 0.3
        let registry = try makeToolRegistry(executor: executor)
        var requestCount = 0

        let controller = makeController(
            { [self] request in
                requestCount += 1
                // 第一轮请求两个工具调用；第二轮不应发生（stop 后）。
                if requestCount == 1 {
                    return (
                        httpResponse(request, status: 200),
                        [
                            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"calculator\",\"arguments\":\"{}\"}},{\"index\":1,\"id\":\"c2\",\"function\":{\"name\":\"calculator\",\"arguments\":\"{}\"}}]}}]}\n\n",
                            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
                            "data: [DONE]\n\n",
                        ],
                        0.02
                    )
                }
                XCTFail("stop 后不应发起第二轮请求")
                return (httpResponse(request, status: 500), [], 0)
            }, toolRegistry: registry)

        let session = store.createSession(title: "竞态")
        store.appendMessage(sessionID: session.id, ChatMessage(role: .user, content: "问题"))
        controller.beginAssistantReply(sessionID: session.id)

        // 等第一个工具调用开始执行后停止。
        try await waitFor { executor.callCount > 0 }
        controller.stop()
        // 等待 in-flight 工具执行真正收尾（stop 会立即清 streamingSessionID）。
        try await waitFor { executor.completedCount >= 1 }
        try await waitFor { controller.streamingSessionID == nil }

        XCTAssertEqual(executor.callCount, 1, "stop 后不应继续执行第二个工具")
        let messages = try XCTUnwrap(store.session(id: session.id)?.messages)
        XCTAssertEqual(
            messages.filter { $0.role == .tool }.count,
            1,
            "stop 时仅第一个工具结果落库"
        )
    }
}
