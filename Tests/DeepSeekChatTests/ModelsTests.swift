import XCTest
@testable import DeepSeekChat

final class ModelsTests: XCTestCase {
    func testChatMessageRoundTrip() throws {
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "你好",
            reasoning: "思考",
            sources: [Source(title: "标题", url: "https://example.com")],
            isSearching: true,
            isError: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded, message)
    }

    func testChatMessageDefaults() {
        let message = ChatMessage(role: .user, content: "hi")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "hi")
        XCTAssertFalse(message.isSearching)
        XCTAssertFalse(message.isError)
        XCTAssertNil(message.reasoning)
        XCTAssertNil(message.sources)
    }

    func testChatSessionRoundTrip() throws {
        let session = ChatSession(
            id: UUID(),
            title: "会话",
            messages: [
                ChatMessage(role: .user, content: "a"),
                ChatMessage(role: .assistant, content: "b", reasoning: "r")
            ],
            createdAt: Date(),
            updatedAt: Date()
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    func testSourceIDEqualsURL() {
        let source = Source(title: nil, url: "https://x.com")
        XCTAssertEqual(source.id, "https://x.com")
    }

    func testModelInfoLookup() {
        XCTAssertEqual(ModelInfo.info("deepseek-v4-flash").name, "DeepSeek V4 Flash")
        XCTAssertTrue(ModelInfo.info("deepseek-v4-flash").supportsResponses)
        XCTAssertFalse(ModelInfo.info("deepseek-v4-pro").supportsResponses)
        // 未知模型回退到第一个
        XCTAssertEqual(ModelInfo.info("unknown-model").id, "deepseek-v4-flash")
    }

    func testEffortRawValuesAndLabels() {
        XCTAssertEqual(Effort.low.rawValue, "low")
        XCTAssertEqual(Effort.high.rawValue, "high")
        XCTAssertEqual(Effort.max.rawValue, "max")
        XCTAssertEqual(Effort.low.label, "低")
        XCTAssertEqual(Effort.high.label, "高")
        XCTAssertEqual(Effort.max.label, "Max")
        XCTAssertEqual(Effort.allCases.count, 3)
    }

    func testAPIMessageCodable() throws {
        let message = APIMessage(role: "assistant", content: "hello")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(APIMessage.self, from: data)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.content, "hello")
    }
}
