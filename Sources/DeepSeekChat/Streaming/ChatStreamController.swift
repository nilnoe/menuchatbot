import Combine
import Foundation

/// 聊天流式编排控制器：发送 / 重试 / 停止 / 流式循环。
///
/// 从 ChatView 抽出，让视图退化为纯展示；生命周期与竞态保护
/// （旧任务收尾不覆盖新一轮状态）集中在此处维护，便于单元测试。
@MainActor
final class ChatStreamController: ObservableObject {
    /// 输入框草稿（视图通过 `$controller.draft` 双向绑定）。
    @Published var draft = ""

    /// 正在流式的会话 / 消息状态；nil 表示空闲。
    /// 非 private：测试可注入完整流式生命周期（与重构前视图状态行为一致）。
    @Published var streamingSessionID: UUID?
    @Published var streamingState: MessageState?

    private var streamTask: Task<Void, Never>?
    private let sessionStore: SessionStoring
    private let settings: SettingsStore
    /// 构造网络客户端：参数依次为 API Key、API 地址（自定义供应商）。
    private let makeClient: (String, String) -> DeepSeekClient

    init(
        sessionStore: SessionStoring,
        settings: SettingsStore,
        makeClient: @escaping @MainActor (String, String) -> DeepSeekClient = {
            DeepSeekClient(baseURL: $1, apiKey: $0)
        }
    ) {
        self.sessionStore = sessionStore
        self.settings = settings
        self.makeClient = makeClient
    }

    // MARK: - 发送 / 停止

    /// 发送一条消息；会话不存在时自动创建。
    /// - Returns: 实际使用的会话 ID（新建时由视图更新选中状态）。
    @discardableResult
    func send(_ preset: String? = nil, selectedSessionID: UUID?) -> UUID? {
        let text = (preset ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, streamingSessionID == nil, settings.keyConfigured else { return nil }
        if preset == nil {
            draft = ""
        }

        var targetID = selectedSessionID
        var targetSession = targetID.flatMap { sessionStore.session(id: $0) }
        if targetSession == nil {
            let created = sessionStore.createSession(title: "新对话")
            targetSession = created
            targetID = created.id
        }
        guard let session = targetSession, let sessionID = targetID else { return nil }

        if session.messages.isEmpty {
            sessionStore.renameSession(id: sessionID, title: String(text.prefix(30)))
        }
        let userMessage = ChatMessage(role: .user, content: text)
        sessionStore.appendMessage(sessionID: sessionID, userMessage)
        beginAssistantReply(sessionID: sessionID)
        return sessionID
    }

    /// 追加一条 assistant 占位消息并启动流式回复（发送与重试共用）。
    func beginAssistantReply(sessionID: UUID) {
        // 只有支持 Responses API 的模型才可能触发搜索状态；
        // 自定义模型即使开着联网搜索开关，也不会进入“搜索中”显示。
        let canSearch =
            settings.webSearch
            && settings.modelInfo(for: settings.model).supportsResponses
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            isSearching: canSearch
        )
        sessionStore.appendMessage(sessionID: sessionID, assistantMessage)
        let assistantState = sessionStore.messageState(for: assistantMessage)
        let history = sessionStore.history(for: sessionID)
        streamingSessionID = sessionID
        streamingState = assistantState

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(sessionID: sessionID, state: assistantState, history: history)
            // 收尾清理前先确认流式状态仍属于本任务：
            // 用户停止后旧任务可能仍在异步收尾，此时若已发起新一轮流式，
            // 直接清 nil 会把新任务的流式状态覆盖掉，导致新回复失去
            // isStreaming 标记 → 走最终 Markdown 路径 → 每分片全文重解析 → 长回复卡死空白。
            if self.streamingSessionID == sessionID, self.streamingState === assistantState {
                self.streamingSessionID = nil
                self.streamingState = nil
            }
        }
    }

    /// 重试：删除末尾的错误回复，重新生成最后一条用户消息的回答。
    func retryLastExchange(in sessionID: UUID) {
        guard streamingSessionID == nil, let session = sessionStore.session(id: sessionID) else {
            return
        }
        if let last = session.messages.last, last.role == .assistant, last.isError {
            sessionStore.removeMessage(sessionID: sessionID, messageID: last.id)
        }
        beginAssistantReply(sessionID: sessionID)
    }

    /// 停止生成：取消任务并清空流式状态。
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        streamingState?.isSearching = false
        streamingSessionID = nil
        streamingState = nil
    }

    // MARK: - 流式循环

    @MainActor
    private func runStream(
        sessionID: UUID,
        state: MessageState,
        history: [APIMessage]
    ) async {
        // 分片节流：增量先进缓冲，每 40ms 聚合提交一次 UI 与存储，
        // 把 SwiftUI 全文重排次数从“每个 token”降到 ~25 次/秒。
        let flushTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
                guard state.hasPendingChanges else { continue }
                state.flushPending()
                sessionStore.syncMessage(state, sessionID: sessionID)
            }
        }

        defer {
            flushTask.cancel()
            state.flushPending()
            state.markStreamEnded()
            // 所有结束路径（完成 / 错误 / 取消）都写回一次并发布，刷新会话元数据。
            sessionStore.commitMessage(state, sessionID: sessionID)
        }

        let client = makeClient(settings.apiKey, settings.activeBaseURL)
        let model = settings.model
        let modelInfo = settings.modelInfo(for: model)
        let canSearch = settings.webSearch && modelInfo.supportsResponses

        let callbacks = StreamCallbacks(
            onDelta: { chunk in
                state.appendContent(chunk)
            },
            onReasoning: { chunk in
                state.appendReasoning(chunk)
            },
            onSearching: {
                state.setSearching(true)
            },
            onSources: { sources in
                state.setSources(sources)
            },
            onDone: {
                state.setSearching(false)
            },
            onError: { message in
                state.setError(message)
            }
        )

        do {
            if canSearch {
                try await client.responses(
                    model: model,
                    input: history,
                    thinking: settings.thinking,
                    effort: settings.effort,
                    webSearch: true,
                    systemPrompt: settings.systemPrompt,
                    temperature: settings.temperature,
                    callbacks: callbacks
                )
            } else {
                try await client.chatCompletions(
                    model: model,
                    messages: history,
                    thinking: settings.thinking,
                    effort: settings.effort,
                    systemPrompt: settings.systemPrompt,
                    temperature: settings.temperature,
                    isCustomProvider: modelInfo.isCustom,
                    callbacks: callbacks
                )
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            state.setError(error.localizedDescription)
        }
    }
}
