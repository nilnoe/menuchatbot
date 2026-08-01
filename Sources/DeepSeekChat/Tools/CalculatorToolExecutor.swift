import DeepSeekChatIndexing
import Foundation

/// T0 计算器工具：Rust 表达式求值（无子进程、无文件 / 网络，T2-2b）。
///
/// 执行器只依赖 `CalculatorService` 协议，不接触 C 类型（ADR-0004 D7）。
struct CalculatorToolExecutor: ToolExecuting {
    private let service: CalculatorService

    init(service: CalculatorService) {
        self.service = service
    }

    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
        let expression = Self.expression(from: request.argumentsJSON)
        let started = Date()
        do {
            let output = try await service.evaluate(expression)
            return ToolExecutionResult(
                toolName: request.toolName,
                success: true,
                output: output,
                errorMessage: nil,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            return ToolExecutionResult(
                toolName: request.toolName,
                success: false,
                output: "",
                errorMessage: error.localizedDescription,
                duration: Date().timeIntervalSince(started)
            )
        }
    }

    /// 从参数 JSON 提取表达式；解析失败返回空串（求值器会给出错误信息）。
    private static func expression(from argumentsJSON: String) -> String {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let expr = json["expr"] as? String
        else {
            return ""
        }
        return expr
    }
}

/// 计算器工具定义（MCP 风格 schema，T2-3）。
enum CalculatorTool {
    static let definition = ToolDefinition(
        name: "calculator",
        description: "计算数学表达式。支持四则运算、括号、幂（^）、取模（%）。例如：\"1 + 2 * 3\"、\"2^10\"。",
        parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "expr": {
                  "type": "string",
                  "description": "要计算的数学表达式"
                }
              },
              "required": ["expr"]
            }
            """,
        tier: .calculator
    )
}
