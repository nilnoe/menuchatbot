import Foundation

/// 进程内工具注册表（ADR-0006 D1：不引入外部 MCP server 子进程）。
///
/// 当前为空：T0 计算器等执行器随 Tier 2 注册。注册时校验名称唯一，
/// 防止工具列表冲突导致 function calling 失效。
final class InProcessToolRegistry: ToolRegistry {
    private struct Registration {
        let definition: ToolDefinition
        let executor: ToolExecuting
    }

    private var registrations: [String: Registration] = [:]

    var availableTools: [ToolDefinition] {
        registrations.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func executor(for toolName: String) -> ToolExecuting? {
        registrations[toolName]?.executor
    }

    /// 注册工具；同名重复注册抛错（调用方须保证唯一性）。
    func register(_ definition: ToolDefinition, executor: ToolExecuting) throws {
        guard !definition.name.isEmpty else {
            throw ToolRegistryError.emptyName
        }
        guard registrations[definition.name] == nil else {
            throw ToolRegistryError.duplicateName(definition.name)
        }
        registrations[definition.name] = Registration(
            definition: definition,
            executor: executor
        )
    }
}

enum ToolRegistryError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "工具名不能为空"
        case .duplicateName(let name):
            return "工具名重复：\(name)"
        }
    }
}
