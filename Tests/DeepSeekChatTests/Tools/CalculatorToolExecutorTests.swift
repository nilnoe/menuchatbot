import XCTest

@testable import DeepSeekChat
@testable import DeepSeekChatIndexing

/// T0 计算器工具执行器：参数解析、成功 / 失败结果、Rust 服务接线（T2-2a）。
final class CalculatorToolExecutorTests: XCTestCase {
    private struct StubCalculatorService: CalculatorService {
        var handler: (String) throws -> String

        func evaluate(_ expression: String) async throws -> String {
            try handler(expression)
        }
    }

    func testExecutesExpressionFromArguments() async throws {
        var received: String?
        let executor = CalculatorToolExecutor(
            service: StubCalculatorService { expression in
                received = expression
                return "7"
            }
        )
        let result = try await executor.execute(
            ToolExecutionRequest(
                toolName: "calculator",
                argumentsJSON: #"{"expr":"1 + 2 * 3"}"#,
                sessionID: nil
            )
        )
        XCTAssertEqual(received, "1 + 2 * 3")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "7")
    }

    func testReturnsErrorResultWhenEvaluationFails() async throws {
        let executor = CalculatorToolExecutor(
            service: StubCalculatorService { _ in
                throw CalculatorError.evaluationFailed("不能除以零")
            }
        )
        let result = try await executor.execute(
            ToolExecutionRequest(
                toolName: "calculator",
                argumentsJSON: #"{"expr":"1/0"}"#,
                sessionID: nil
            )
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorMessage, "表达式求值失败：不能除以零")
    }

    func testMalformedArgumentsProducesEmptyExpression() async throws {
        let executor = CalculatorToolExecutor(
            service: StubCalculatorService { expression in
                XCTAssertEqual(expression, "")
                return "0"
            }
        )
        let result = try await executor.execute(
            ToolExecutionRequest(
                toolName: "calculator",
                argumentsJSON: "not json",
                sessionID: nil
            )
        )
        XCTAssertTrue(result.success)
    }

    func testDefinitionMatchesMCPShape() {
        XCTAssertEqual(CalculatorTool.definition.name, "calculator")
        XCTAssertEqual(CalculatorTool.definition.tier, .calculator)
        let schema =
            try? JSONSerialization.jsonObject(
                with: Data(CalculatorTool.definition.parametersJSONSchema.utf8)
            ) as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual(
            (schema?["required"] as? [String])?.first,
            "expr",
            "expr 应为必填参数"
        )
    }
}
