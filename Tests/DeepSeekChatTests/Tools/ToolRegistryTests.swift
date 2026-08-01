import XCTest

@testable import DeepSeekChat

/// 工具注册表契约：默认空、注册 / 查询、唯一性、分级（Tier 1 第二批）。
final class ToolRegistryTests: XCTestCase {
    private struct StubExecutor: ToolExecuting {
        func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
            ToolExecutionResult(
                toolName: request.toolName,
                success: true,
                output: "stub",
                duration: 0
            )
        }
    }

    private func definition(_ name: String, tier: ToolTier = .calculator) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: "描述",
            parametersJSONSchema: "{\"type\":\"object\"}",
            tier: tier
        )
    }

    func testRegistryStartsEmpty() {
        let registry = InProcessToolRegistry()
        XCTAssertTrue(registry.availableTools.isEmpty)
        XCTAssertNil(registry.executor(for: "calculator"))
    }

    func testRegisterAndResolve() throws {
        let registry = InProcessToolRegistry()
        let calculator = definition("calculator")
        try registry.register(calculator, executor: StubExecutor())

        XCTAssertEqual(registry.availableTools, [calculator])
        XCTAssertNotNil(registry.executor(for: "calculator"))
    }

    func testDuplicateNameRejected() throws {
        let registry = InProcessToolRegistry()
        try registry.register(definition("calc"), executor: StubExecutor())
        XCTAssertThrowsError(try registry.register(definition("calc"), executor: StubExecutor())) {
            error in
            XCTAssertEqual(error as? ToolRegistryError, .duplicateName("calc"))
        }
    }

    func testEmptyNameRejected() {
        let registry = InProcessToolRegistry()
        XCTAssertThrowsError(try registry.register(definition(""), executor: StubExecutor())) {
            error in
            XCTAssertEqual(error as? ToolRegistryError, .emptyName)
        }
    }

    func testUnknownToolReturnsNil() throws {
        let registry = InProcessToolRegistry()
        try registry.register(definition("calc"), executor: StubExecutor())
        XCTAssertNil(registry.executor(for: "nope"))
    }

    func testAvailableToolsSortedByName() throws {
        let registry = InProcessToolRegistry()
        try registry.register(definition("zebra", tier: .python), executor: StubExecutor())
        try registry.register(definition("alpha", tier: .calculator), executor: StubExecutor())
        XCTAssertEqual(registry.availableTools.map(\.name), ["alpha", "zebra"])
    }
}
