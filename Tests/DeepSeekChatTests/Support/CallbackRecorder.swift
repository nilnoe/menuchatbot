import Foundation

@testable import DeepSeekChat

/// 流式回调记录器（测试双）。
///
/// 把 `StreamCallbacks` 的全部回调收敛到内存数组 / 计数器，
/// 测试只需断言 `deltas` / `reasoning` / `usages` / `errors` 等字段即可。
final class CallbackRecorder {
    var deltas: [String] = []
    var reasoning: [String] = []
    var searchingCount = 0
    var sources: [[Source]] = []
    var usages: [TokenUsage] = []
    var doneCount = 0
    var errors: [String] = []
    /// 工具调用分片：(index, id, name, arguments 片段)。
    var toolCallDeltas: [(Int, String?, String?, String)] = []
    var finishedToolCalls: [[APIToolCall]] = []

    var callbacks: StreamCallbacks {
        StreamCallbacks(
            onDelta: { [self] in deltas.append($0) },
            onReasoning: { [self] in reasoning.append($0) },
            onToolCallDelta: { [self] index, id, name, arguments in
                toolCallDeltas.append((index, id, name, arguments))
            },
            onToolCallsFinished: { [self] in finishedToolCalls.append($0) },
            onSearching: { [self] in searchingCount += 1 },
            onSources: { [self] in sources.append($0) },
            onUsage: { [self] in usages.append($0) },
            onDone: { [self] in doneCount += 1 },
            onError: { [self] in errors.append($0) }
        )
    }
}
