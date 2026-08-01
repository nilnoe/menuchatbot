import Combine
import Foundation

/// 单条消息的可观察状态。
///
/// 流式回复期间每次 token 分片只更新当前消息的 `MessageState`，
/// 由对应消息行单独观察，避免触发整棵视图树（会话列表 / 全部消息）重算。
///
/// 文本累积采用「增量缓冲 + 定时聚合」：
/// 分片先追加进 `pendingContent`（不触发发布），由调用方按 30~60ms 窗口调用
/// `flushPending()` 一次性提交。否则每分片都会让 SwiftUI 对**全文**重新排版，
/// 单条长消息会退化成 O(n²)。
final class MessageState: ObservableObject, Identifiable {
    let id: UUID
    let role: Role
    let createdAt: Date

    @Published private(set) var content: String
    @Published private(set) var reasoning: String?
    @Published var sources: [Source]?
    /// assistant 消息发起的工具调用（透明展示，T2-3c）。
    @Published var toolCalls: [ChatToolCall]?
    /// tool 角色消息的工具名。
    @Published var toolName: String?
    /// 流式结束后由 API 返回的 token 用量。
    @Published private(set) var usage: TokenUsage?
    @Published var isSearching: Bool
    @Published private(set) var isError: Bool
    /// 消息自身是否处于流式（由本对象维护，不依赖 ChatView 的可覆盖状态）。
    /// 即使外部流式状态被旧任务收尾误清，行内仍走节流的实时渲染路径。
    @Published private(set) var isStreaming = false

    /// 尚未聚合到 UI 的流式增量。
    private var pendingContent = ""
    private var pendingReasoning = ""

    init(message: ChatMessage) {
        self.id = message.id
        self.role = message.role
        self.createdAt = message.createdAt
        self.content = message.content
        self.reasoning = message.reasoning
        self.sources = message.sources
        self.toolCalls = message.toolCalls
        self.toolName = message.toolName
        self.usage = message.usage
        self.isSearching = message.isSearching
        self.isError = message.isError
    }

    var hasPendingChanges: Bool {
        !pendingContent.isEmpty || !pendingReasoning.isEmpty
    }

    /// 追加正文分片：只进缓冲，不发布。
    func appendContent(_ chunk: String) {
        pendingContent += chunk
        if !isStreaming { isStreaming = true }
    }

    /// 追加思考分片：只进缓冲，不发布。
    func appendReasoning(_ chunk: String) {
        pendingReasoning += chunk
        if !isStreaming { isStreaming = true }
    }

    /// 流式结束（完成 / 错误 / 取消）时调用，恢复非流式渲染。
    func markStreamEnded() {
        if isStreaming { isStreaming = false }
    }

    /// 把缓冲的增量一次性提交给 UI（触发一次 objectWillChange）。
    func flushPending() {
        if !pendingContent.isEmpty {
            content += pendingContent
            pendingContent = ""
        }
        if !pendingReasoning.isEmpty {
            reasoning = (reasoning ?? "") + pendingReasoning
            pendingReasoning = ""
        }
    }

    func setSearching(_ value: Bool) {
        isSearching = value
    }

    func setSources(_ sources: [Source]) {
        self.sources = sources
        isSearching = false
    }

    func setUsage(_ usage: TokenUsage) {
        self.usage = usage
    }

    /// 出错时丢弃未提交的增量，直接替换为错误信息。
    func setError(_ message: String) {
        pendingContent = ""
        pendingReasoning = ""
        content = message
        isError = true
        isSearching = false
    }
}
