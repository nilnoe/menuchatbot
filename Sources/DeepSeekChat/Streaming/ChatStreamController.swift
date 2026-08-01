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

    /// 存储落库节流计数（Tier 1-3）：UI 保持 40ms 聚合，落库每 6 次（~240ms）
    /// 一次，消除流式写放大；最终内容由 commitMessage 兜底。
    private var storageFlushTick = 0

    /// 统一上下文预算：历史截断等由 ContextBuilder 负责（Tier 1 第二批）。
    private let contextBuilder: ContextBuilder
    /// 工具注册表（T2-3）：nil 表示未装配，工具调用不启用。
    private let toolRegistry: ToolRegistry?
    /// 工具调用轮次上限（ADR-0006 D3）。
    private let maxToolRounds: Int
    /// 资料库检索注入（Tier 3-3）：nil = 未启用 / 无资料库，不注入。
    private let retrievalInjector: RetrievalInjecting?
    /// 审计记录器（ADR-0009 B/C 域：轮次上限、工具执行）。
    private let audit: AuditLogging
    /// 本次发送的关联 ID（AU-9：贯穿工具轮次与流式）。
    private var currentRequestID = ""

    private var streamTask: Task<Void, Never>?
    private let sessionStore: SessionStoring
    private let settings: SettingsStore
    /// 构造网络客户端：参数依次为 API Key、API 地址（自定义供应商）。
    private let makeClient: (String, String) -> DeepSeekClient

    init(
        sessionStore: SessionStoring,
        settings: SettingsStore,
        contextBuilder: ContextBuilder = ContextBuilder(),
        toolRegistry: ToolRegistry? = nil,
        maxToolRounds: Int = AppConfiguration.defaultMaxToolRounds,
        retrievalInjector: RetrievalInjecting? = nil,
        audit: AuditLogging = NullAuditLogger(),
        makeClient: @escaping @MainActor (String, String) -> DeepSeekClient = {
            DeepSeekClient(baseURL: $1, apiKey: $0)
        }
    ) {
        self.sessionStore = sessionStore
        self.settings = settings
        self.contextBuilder = contextBuilder
        self.toolRegistry = toolRegistry
        self.maxToolRounds = maxToolRounds
        self.retrievalInjector = retrievalInjector
        self.audit = audit
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
        currentRequestID = UUID().uuidString

        var targetID = selectedSessionID
        if targetID.flatMap({ sessionStore.summary(id: $0) }) == nil {
            targetID = sessionStore.createSession(title: "新对话").id
        }
        guard let sessionID = targetID else { return nil }

        if sessionStore.messages(for: sessionID).isEmpty {
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
        let history = contextBuilder.buildHistory(sessionStore.history(for: sessionID))
        streamingSessionID = sessionID
        streamingState = assistantState

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let finalState = await self.runStream(
                sessionID: sessionID,
                history: history,
                canSearch: canSearch,
                firstState: assistantState
            )
            // 收尾清理前先确认流式状态仍属于本任务：
            // 用户停止后旧任务可能仍在异步收尾，此时若已发起新一轮流式，
            // 直接清 nil 会把新任务的流式状态覆盖掉，导致新回复失去
            // isStreaming 标记 → 走最终 Markdown 路径 → 每分片全文重解析 → 长回复卡死空白。
            if self.streamingSessionID == sessionID, self.streamingState === finalState {
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
        currentRequestID = UUID().uuidString
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
        history: [APIMessage],
        canSearch: Bool,
        firstState: MessageState
    ) async -> MessageState {
        let requestID = currentRequestID.isEmpty ? nil : currentRequestID
        let enabledTools = enabledToolDefinitions()
        var currentHistory = history
        var currentState = firstState
        var round = 0
        var limitMessageSent = false

        // 资料库检索注入（T3-3b）：首轮前对最后一条用户消息检索；
        // 命中则注入上下文（system 前缀）并把来源挂到首个 assistant 消息
        // （Source 卡片复用：标题 = 文件名，url = 路径）。
        if let retrievalInjector {
            let query = history.last(where: { $0.role == "user" })?.content ?? ""
            let result = await retrievalInjector.retrieve(for: query)
            if !result.context.isEmpty {
                currentHistory.insert(
                    APIMessage(role: "system", content: result.context),
                    at: 0
                )
                if !result.sources.isEmpty {
                    sessionStore.updateMessage(
                        sessionID: sessionID,
                        messageID: currentState.id
                    ) { $0.sources = result.sources }
                    currentState.setSources(result.sources)
                }
            }
        }

        while true {
            guard !Task.isCancelled else { break }
            let toolCalls = await streamRound(
                sessionID: sessionID,
                state: currentState,
                history: currentHistory,
                canSearch: canSearch,
                tools: enabledTools
            )
            // nil = 出错 / 取消（streamRound 内部已提交并标记错误）。
            guard let toolCalls else { break }

            if !toolCalls.isEmpty {
                // 把工具调用附到已落库的 assistant 消息上（透明展示 + 回传 API）。
                let messageID = currentState.id
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.toolCalls = toolCalls.map {
                        ChatToolCall(
                            id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
                    }
                }
                currentState.toolCalls = toolCalls.map {
                    ChatToolCall(
                        id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
                }
            }
            currentHistory.append(
                APIMessage(
                    role: "assistant",
                    content: currentState.content,
                    toolCalls: toolCalls
                )
            )

            // 无工具调用 = 本轮已给出最终答案。
            if toolCalls.isEmpty { break }

            round += 1
            if round > maxToolRounds {
                // 超过轮次上限：不再执行工具，提示模型直接作答（T2-3b）。
                audit.record(
                    domain: .permission,
                    severity: .warning,
                    category: AuditCategory.roundLimitEnforced,
                    message: "工具调用轮次已达上限，强制收敛",
                    sessionID: sessionID,
                    requestID: requestID,
                    metadata: ["round": String(round), "max": String(maxToolRounds)]
                )
                if limitMessageSent { break }
                let note = "工具调用轮次已达上限（\(maxToolRounds)），请基于已有信息直接给出最终答案。"
                appendToolMessage(
                    sessionID: sessionID,
                    id: "round-limit-\(round)",
                    name: "system",
                    content: note,
                    to: &currentHistory
                )
                limitMessageSent = true
                // 提示语先落库，再开新一轮 assistant 消息，保证最终答案排在提示语之后。
                let nextMessage = ChatMessage(role: .assistant, content: "", isSearching: canSearch)
                sessionStore.appendMessage(sessionID: sessionID, nextMessage)
                currentState = sessionStore.messageState(for: nextMessage)
                streamingState = currentState
                continue
            }

            for call in toolCalls {
                guard !Task.isCancelled else { break }
                let summary = await executeTool(call, sessionID: sessionID)
                appendToolMessage(
                    sessionID: sessionID,
                    id: call.id,
                    name: call.function.name,
                    content: summary,
                    to: &currentHistory
                )
            }
            guard !Task.isCancelled else { break }

            // 准备下一轮 assistant 消息。
            let nextMessage = ChatMessage(role: .assistant, content: "", isSearching: canSearch)
            sessionStore.appendMessage(sessionID: sessionID, nextMessage)
            currentState = sessionStore.messageState(for: nextMessage)
            streamingState = currentState
        }
        return currentState
    }

    /// 单轮流式：40ms 聚合节流 + 一次 API 调用；返回本轮工具调用（nil = 出错 / 取消）。
    @MainActor
    private func streamRound(
        sessionID: UUID,
        state: MessageState,
        history: [APIMessage],
        canSearch: Bool,
        tools: [ToolDefinition]
    ) async -> [APIToolCall]? {
        // 分片节流：增量先进缓冲，每 40ms 聚合提交一次 UI 与存储，
        // 把 SwiftUI 全文重排次数从“每个 token”降到 ~25 次/秒。
        let flushTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
                guard state.hasPendingChanges else { continue }
                state.flushPending()
                guard let self else { return }
                self.storageFlushTick += 1
                if self.storageFlushTick.isMultiple(of: 6) {
                    sessionStore.syncMessage(state, sessionID: sessionID)
                }
            }
        }

        defer {
            flushTask.cancel()
            storageFlushTick = 0
            state.flushPending()
            state.markStreamEnded()
            // 所有结束路径（完成 / 错误 / 取消）都写回一次并发布，刷新会话元数据。
            sessionStore.commitMessage(state, sessionID: sessionID)
        }

        var pendingToolCalls: [APIToolCall] = []
        let client = makeClient(settings.apiKey, settings.activeBaseURL)
        let model = settings.model
        let modelInfo = settings.modelInfo(for: model)

        let callbacks = StreamCallbacks(
            onDelta: { chunk in
                state.appendContent(chunk)
            },
            onReasoning: { chunk in
                state.appendReasoning(chunk)
            },
            onToolCallsFinished: { calls in
                pendingToolCalls = calls
            },
            onSearching: {
                state.setSearching(true)
            },
            onSources: { sources in
                state.setSources(sources)
            },
            onUsage: { usage in
                state.setUsage(usage)
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
                    tools: tools,
                    callbacks: callbacks
                )
            }
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            state.setError(error.localizedDescription)
            return nil
        }
        return pendingToolCalls
    }

    /// 当前设置下启用的工具清单（注册表 ∩ 设置开关）。
    private func enabledToolDefinitions() -> [ToolDefinition] {
        guard let toolRegistry else { return [] }
        return toolRegistry.availableTools.filter { tool in
            switch tool.tier {
            case .calculator:
                return settings.toolCalculatorEnabled
            case .readFile:
                return settings.toolReadFileEnabled
            case .python:
                return settings.toolPythonEnabled
            }
        }
    }

    /// 执行一次工具调用，返回写入会话历史的结果摘要（T2-3c 透明展示）。
    private func executeTool(_ call: APIToolCall, sessionID: UUID) async -> String {
        let started = Date()
        let requestID = currentRequestID.isEmpty ? nil : currentRequestID
        let argsSummary = AuditRedactor.summary(for: call.function.arguments)
        let toolMetadata = [
            "tool": call.function.name,
            "args": argsSummary,
        ]
        audit.record(
            domain: .tool,
            category: AuditCategory.executionStart,
            message: "工具执行开始：\(call.function.name)",
            sessionID: sessionID,
            requestID: requestID,
            metadata: toolMetadata
        )
        guard let executor = toolRegistry?.executor(for: call.function.name) else {
            audit.record(
                domain: .tool,
                severity: .warning,
                category: AuditCategory.notRegistered,
                message: "工具未注册：\(call.function.name)",
                sessionID: sessionID,
                requestID: requestID,
                metadata: toolMetadata
            )
            return toolFailureRecord(
                call: call,
                duration: nil,
                args: call.function.arguments,
                error: "工具 \(call.function.name) 未注册"
            )
        }
        let request = ToolExecutionRequest(
            toolName: call.function.name,
            argumentsJSON: call.function.arguments,
            sessionID: sessionID
        )
        do {
            let result = try await executor.execute(request)
            recordToolEnd(
                success: result.success,
                call: call,
                sessionID: sessionID,
                requestID: requestID,
                result: result
            )
            if result.success {
                return toolSuccessRecord(
                    call: call,
                    duration: result.duration,
                    args: call.function.arguments,
                    output: result.output
                )
            }
            return toolFailureRecord(
                call: call,
                duration: result.duration,
                args: call.function.arguments,
                error: result.errorMessage ?? "未知错误"
            )
        } catch {
            recordToolEnd(
                success: false,
                call: call,
                sessionID: sessionID,
                requestID: requestID,
                error: error.localizedDescription
            )
            return toolFailureRecord(
                call: call,
                duration: Date().timeIntervalSince(started),
                args: call.function.arguments,
                error: error.localizedDescription
            )
        }
    }

    /// T4-4 完整执行记录（成功）：状态 / 工具名 / 耗时 / 参数 / 结果摘要，
    /// 写入会话历史并随 tool 消息回传 API（下一轮模型可读）。
    private func toolSuccessRecord(
        call: APIToolCall,
        duration: TimeInterval,
        args: String,
        output: String
    ) -> String {
        """
        工具执行成功（\(call.function.name)，耗时 \(Self.formatToolDuration(duration))）
        参数：\(Self.truncatedToolArguments(args))
        结果：\(output)
        """
    }

    /// T4-4 完整执行记录（失败 / 异常 / 未注册共用）；duration 为 nil 表示未执行。
    private func toolFailureRecord(
        call: APIToolCall,
        duration: TimeInterval?,
        args: String,
        error: String
    ) -> String {
        let durationText = duration.map { "，耗时 \(Self.formatToolDuration($0))" } ?? ""
        return """
            工具执行失败（\(call.function.name)\(durationText)）
            参数：\(Self.truncatedToolArguments(args))
            错误：\(error)
            """
    }

    private static func formatToolDuration(_ interval: TimeInterval) -> String {
        String(format: "%.3f", interval) + "s"
    }

    /// 参数写入历史前截断（上限 200 字符），防超长参数撑爆上下文预算。
    private static func truncatedToolArguments(_ args: String) -> String {
        guard args.count > 200 else { return args }
        return String(args.prefix(200)) + "…（参数过长，已截断）"
    }

    /// 工具执行结束事件（成功 / 失败共用，AU-9 start/end 成对）。
    private func recordToolEnd(
        success: Bool,
        call: APIToolCall,
        sessionID: UUID,
        requestID: String?,
        result: ToolExecutionResult? = nil,
        error: String? = nil
    ) {
        var metadata: [String: String] = [
            "tool": call.function.name,
            "args": AuditRedactor.summary(for: call.function.arguments),
            "success": String(success),
        ]
        if let result {
            metadata["duration"] = String(format: "%.3f", result.duration)
            metadata["output"] = AuditRedactor.truncated(result.output)
        }
        if let error {
            metadata["error"] = AuditRedactor.truncated(error)
        }
        audit.record(
            domain: .tool,
            severity: success ? .info : .warning,
            category: success ? AuditCategory.executionSuccess : AuditCategory.executionFailed,
            message: success ? "工具执行成功：\(call.function.name)" : "工具执行失败：\(call.function.name)",
            sessionID: sessionID,
            requestID: requestID,
            metadata: metadata
        )
    }

    /// 追加一条 tool 角色消息（历史 + 会话），保证下一轮 API 请求可回传。
    private func appendToolMessage(
        sessionID: UUID,
        id: String,
        name: String,
        content: String,
        to history: inout [APIMessage]
    ) {
        let message = ChatMessage(
            role: .tool,
            content: content,
            toolCallID: id,
            toolName: name
        )
        sessionStore.appendMessage(sessionID: sessionID, message)
        history.append(
            APIMessage(role: "tool", content: content, toolCallID: id, name: name)
        )
    }
}
