import Foundation

/// 流式 tool_calls 增量拼装器（Chat Completions）。
///
/// SSE 中 `delta.tool_calls` 按 index 分片到达：id / name 只在首片出现，
/// arguments 按字符串片段累计。本类型纯函数式，便于单元测试。
struct ToolCallAccumulator {
    private struct Part {
        var id: String?
        var name: String?
        var arguments: String
    }

    private var parts: [Int: Part] = [:]

    var isEmpty: Bool {
        parts.isEmpty
    }

    /// 追加一个分片。
    mutating func append(index: Int, id: String?, name: String?, argumentsFragment: String) {
        var part = parts[index] ?? Part(id: nil, name: nil, arguments: "")
        if let id, part.id == nil {
            part.id = id
        }
        if let name, part.name == nil {
            part.name = name
        }
        part.arguments += argumentsFragment
        parts[index] = part
    }

    /// 按 index 升序拼装完整调用；缺少 name 的片段丢弃（异常流保护）。
    func assembled() -> [APIToolCall] {
        parts.sorted { $0.key < $1.key }.compactMap { _, part in
            guard let name = part.name, !name.isEmpty else { return nil }
            return APIToolCall(
                id: part.id ?? "",
                function: APIFunctionCall(name: name, arguments: part.arguments)
            )
        }
    }
}
