import Foundation

/// 工具分级（ADR-0006 D2）：T0 计算器 → T1 只读文件 → T2 Python 沙箱。
/// 通用 shell（T3）明确不做。
enum ToolTier: Int, Codable, Equatable {
    case calculator = 0
    case readFile = 1
    case python = 2
}

/// 工具定义：遵循 MCP 约定（name / description / parameters JSON Schema），
/// 由 ToolRegistry 暴露给调用方（模型 function calling 的工具列表）。
struct ToolDefinition: Equatable, Codable {
    var name: String
    var description: String
    var parametersJSONSchema: String
    var tier: ToolTier
}

/// 一次工具执行请求（参数为 JSON 文本，由具体执行器解析）。
struct ToolExecutionRequest: Equatable {
    var toolName: String
    var argumentsJSON: String
    /// 发起工具调用的会话（审计 / 上下文记账用）。
    var sessionID: UUID?
}

/// 工具执行结果：success + 输出 / 错误 + 耗时（审计字段，Tier 4 落会话历史）。
struct ToolExecutionResult: Equatable {
    var toolName: String
    var success: Bool
    var output: String
    var errorMessage: String?
    var duration: TimeInterval
}

/// 工具执行器：具体实现随 Tier 2 落地（T0 计算器 → T1 read_file → T2 沙箱）。
protocol ToolExecuting {
    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult
}

/// 工具注册表：模型可调用的工具清单 + 执行器解析。
///
/// 只读 / 非 Agent 硬约束（ADR-0006 D3）：注册表中**不存在**写 / 删类工具，
/// 这是由工具集合本身保证的，而非运行时禁用。
protocol ToolRegistry: AnyObject {
    var availableTools: [ToolDefinition] { get }
    func executor(for toolName: String) -> ToolExecuting?
}
