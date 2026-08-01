import Foundation

/// 一次 function calling 调用（Chat Completions 的 assistant.tool_calls 项）。
struct APIToolCall: Codable, Equatable {
    var id: String
    var type: String = "function"
    var function: APIFunctionCall
}

struct APIFunctionCall: Codable, Equatable {
    var name: String
    /// 参数 JSON 文本（模型生成，由执行器解析）。
    var arguments: String
}

struct APIMessage: Codable, Equatable {
    var role: String
    var content: String
    /// assistant 消息携带的工具调用（回传 API 时原样序列化）。
    var toolCalls: [APIToolCall]?
    /// tool 角色消息：对应的工具调用 ID。
    var toolCallID: String?
    /// tool 角色消息：工具名。
    var name: String?

    init(
        role: String,
        content: String,
        toolCalls: [APIToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }
}
