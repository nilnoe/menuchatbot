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
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, [String], TimeInterval)
    ) -> ChatStreamController {
        DelayedStreamingURLProtocol.handler = handler
        return ChatStreamController(
            sessionStore: store,
            settings: settings,
            makeClient: { _, baseURL in
                DeepSeekClient(
                    baseURL: baseURL, apiKey: "test-key",
                    session: self.makeDelayedStreamingURLSession())
            }
        )
    }

    private func waitFor(
        timeout: Duration = .seconds(3),
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
}
