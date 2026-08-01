import XCTest

@testable import DeepSeekChat

/// 深度思考 v1（T2-4）：`reasoning_effort=max` 在 Chat Completions 与
/// Responses 两条链路各自正确携带（纯 API 参数过渡方案）。
final class DeepSeekClientEffortMaxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testChatCompletionsSendsEffortMax() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "enabled")
            XCTAssertEqual(json["reasoning_effort"] as? String, "max")
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.chatCompletions(
            model: "deepseek-v4-flash",
            messages: [APIMessage(role: "user", content: "难题")],
            thinking: true,
            effort: .max,
            callbacks: CallbackRecorder().callbacks
        )
    }

    @MainActor
    func testResponsesSendsEffortMax() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = try httpBody(of: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "max")
            return (httpResponse(request, status: 200), Data("data: [DONE]\n\n".utf8))
        }
        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        try await client.responses(
            model: "deepseek-v4-flash",
            input: [APIMessage(role: "user", content: "难题")],
            thinking: true,
            effort: .max,
            webSearch: false,
            callbacks: CallbackRecorder().callbacks
        )
    }

    /// UI 档位完整性：设置页遍历 Effort.allCases，Max 必须存在且可持久化。
    func testEffortMaxIsSelectableTier() {
        XCTAssertTrue(Effort.allCases.contains(.max))
        XCTAssertEqual(Effort.max.rawValue, "max")
    }
}
