import Foundation
import XCTest

@testable import DeepSeekChat

/// AU-9：工具执行 start/end 成对、requestID 一致、执行数与事件 1:1；
/// 轮次上限产生 permission.roundLimitEnforced。
@MainActor
final class AuditToolLoopTests: XCTestCase {
    private var tempDir: URL!
    private var store: SessionStore!
    private var settings: SettingsStore!
    private var recorder: AuditRecorderSink!
    private var logger: AuditLogger!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditTool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SessionStore(storageDirectory: tempDir)
        let keychain = MockKeychain()
        keychain.storage["apiKey"] = "test-key"
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: "AuditTool-\(UUID().uuidString)")!,
            keychain: keychain,
            keychainSaveDelay: .zero
        )
        recorder = AuditRecorderSink()
        logger = makeAuditLogger(sinks: [recorder], batchSize: 1000)
    }

    override func tearDownWithError() throws {
        DelayedStreamingURLProtocol.handler = nil
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testToolExecutionProducesPairedStartEndEventsAU9() async throws {
        let executor = RecordingToolExecutor()
        let registry = try makeToolRegistry(executor: executor)
        var requestCount = 0
        let controller = makeController(
            { [self] request in
                requestCount += 1
                if requestCount == 1 {
                    return (httpResponse(request, status: 200), toolCallChunks(), 0.02)
                }
                return (
                    httpResponse(request, status: 200),
                    [
                        "data: {\"choices\":[{\"delta\":{\"content\":\"答案是 3\"}}]}\n\n",
                        "data: [DONE]\n\n",
                    ],
                    0.02
                )
            },
            toolRegistry: registry
        )

        let sessionID = controller.send("计算 1+2", selectedSessionID: nil)
        let sid = try XCTUnwrap(sessionID)
        try await waitFor { controller.streamingSessionID == nil }
        logger.flushSync()

        let starts = recorder.events(category: AuditCategory.executionStart)
        let ends = recorder.events(domain: .tool).filter {
            $0.category == AuditCategory.executionSuccess
                || $0.category == AuditCategory.executionFailed
        }
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(starts.count, 1, "AU-9：每次执行一个 start")
        XCTAssertEqual(ends.count, 1, "AU-9：每次执行一个 end")
        XCTAssertEqual(starts.first?.sessionID, sid)
        XCTAssertEqual(
            starts.first?.requestID, ends.first?.requestID, "AU-9：start/end requestID 一致")
        XCTAssertNotNil(starts.first?.requestID, "AU-9：send 生成的 requestID 贯穿")
        XCTAssertEqual(starts.first?.category, AuditCategory.executionStart)
        XCTAssertEqual(ends.first?.category, AuditCategory.executionSuccess)
        XCTAssertTrue(
            starts.first?.metadataJSON?.contains("calculator") == true,
            "AU-9：事件应带工具名"
        )
    }

    func testRoundLimitProducesAuditEventAU9() async throws {
        let executor = RecordingToolExecutor()
        let registry = try makeToolRegistry(executor: executor)
        var requestCount = 0
        let controller = makeController(
            { [self] request in
                requestCount += 1
                if requestCount <= 4 {
                    return (
                        httpResponse(request, status: 200),
                        toolCallChunks(id: "call_\(requestCount)"),
                        0.02
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
            },
            toolRegistry: registry,
            maxToolRounds: 2
        )

        _ = controller.send("问题", selectedSessionID: nil)
        try await waitFor { controller.streamingSessionID == nil }
        logger.flushSync()

        XCTAssertEqual(executor.callCount, 2, "AU-9：超过上限后不再执行工具")
        XCTAssertGreaterThanOrEqual(
            recorder.events(category: AuditCategory.roundLimitEnforced).count, 1,
            "AU-9：轮次上限强制收敛应产生审计事件"
        )
    }

    // MARK: - 脚手架

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
            audit: logger,
            makeClient: { _, baseURL in
                DeepSeekClient(
                    baseURL: baseURL,
                    apiKey: "test-key",
                    session: self.makeDelayedStreamingURLSession()
                )
            }
        )
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

    private func toolCallChunks(id: String = "call_1") -> [String] {
        let arguments = #"{"expr":"1+2"}"#
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

    private final class RecordingToolExecutor: ToolExecuting, @unchecked Sendable {
        private(set) var callCount = 0
        var delay: TimeInterval = 0

        func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
            callCount += 1
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay * 1000))
            }
            return ToolExecutionResult(
                toolName: request.toolName,
                success: true,
                output: "3",
                errorMessage: nil,
                duration: 0
            )
        }
    }
}
