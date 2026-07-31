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
                ChatMessage(role: .assistant, content: "b", reasoning: "r"),
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

    func testModelCatalogBuiltinLookup() {
        let custom: [CustomModel] = []
        XCTAssertEqual(
            ModelCatalog.info("deepseek-v4-flash", custom: custom).name, "DeepSeek V4 Flash")
        XCTAssertTrue(ModelCatalog.info("deepseek-v4-flash", custom: custom).supportsResponses)
        XCTAssertFalse(ModelCatalog.info("deepseek-v4-pro", custom: custom).supportsResponses)
        // 未知模型回退到第一个内置模型
        XCTAssertEqual(ModelCatalog.info("unknown-model", custom: custom).id, "deepseek-v4-flash")
    }

    func testModelCatalogMergesCustomModels() {
        let custom = [
            CustomModel(id: "gpt-4o", name: "GPT-4o"),
            CustomModel(id: "claude-sonnet", name: "Claude Sonnet"),
        ]
        let models = ModelCatalog.all(custom: custom)
        XCTAssertEqual(models.count, 4)

        let gpt = ModelCatalog.info("gpt-4o", custom: custom)
        XCTAssertEqual(gpt.name, "GPT-4o")
        XCTAssertTrue(gpt.isCustom)
        XCTAssertFalse(gpt.supportsResponses, "自定义模型不支持 Responses API")

        let claude = ModelCatalog.info("claude-sonnet", custom: custom)
        XCTAssertEqual(claude.shortName, "Claude Sonnet", "自定义模型短标签用展示名")

        // 自定义模型 ID 优先于内置模型（同名覆盖）
        XCTAssertTrue(
            ModelCatalog.info("deepseek-v4-flash", custom: custom).id == "deepseek-v4-flash")
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
