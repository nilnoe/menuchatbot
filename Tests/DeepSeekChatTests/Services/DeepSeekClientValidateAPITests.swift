import XCTest

@testable import DeepSeekChat

/// validateAPIKey：成功、无效 Key、网络错误、自定义 base_url。
final class DeepSeekClientValidateAPITests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testValidateAPIKeySuccess() async throws {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.url?.path, "/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let body = Data(
                #"{"data":[{"id":"deepseek-v4-flash"},{"id":"deepseek-v4-pro"}]}"#.utf8
            )
            return (httpResponse(request, status: 200), body)
        }

        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        let models = try await client.validateAPIKey()
        XCTAssertEqual(models, ["deepseek-v4-flash", "deepseek-v4-pro"])
    }

    @MainActor
    func testValidateAPIKeyRejectsBadKey() async throws {
        MockURLProtocol.handler = { [self] request in
            let body = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
            return (httpResponse(request, status: 401), body)
        }

        let client = DeepSeekClient(apiKey: "bad-key", session: makeMockURLSession())
        do {
            _ = try await client.validateAPIKey()
            XCTFail("无效 Key 应抛错")
        } catch let error as DeepSeekError {
            XCTAssertEqual(error.localizedDescription, "invalid api key")
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    @MainActor
    func testValidateAPIKeyNetworkErrorThrows() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let client = DeepSeekClient(apiKey: "sk-test", session: makeMockURLSession())
        do {
            _ = try await client.validateAPIKey()
            XCTFail("网络错误应抛出")
        } catch {
            // 期望抛出网络错误
        }
    }

    @MainActor
    func testValidateAPIKeyUsesCustomBaseURL() async throws {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example.com/v1/models",
                "Key 校验应打到自定义供应商的 /models 接口"
            )
            let body = Data(#"{"data":[{"id":"gpt-4o"}]}"#.utf8)
            return (httpResponse(request, status: 200), body)
        }

        let client = DeepSeekClient(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-test",
            session: makeMockURLSession()
        )
        let models = try await client.validateAPIKey()
        XCTAssertEqual(models, ["gpt-4o"])
    }
}
