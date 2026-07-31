import Combine
import SwiftUI

/// 滚动测量：内容顶部（零高锚点）相对滚动视图顶部的偏移。用户滚动时变化。
private struct ChatTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 内容总高度（倒置布局下用于计算“是否贴底”）。
private struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var settings: SettingsStore

    @Binding var selectedID: UUID?
    var onOpenSettings: () -> Void
    var onToggleSidebar: () -> Void

    @State private var draft = ""
    // 内部（非 private）以便测试驱动完整流式生命周期。
    @State var streamingSessionID: UUID?
    @State var streamingState: MessageState?
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    // MARK: - 滚动状态
    @State private var topOffset: CGFloat = 0
    @State private var lastTopOffset: CGFloat?
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// 用户是否贴底。只有贴底时才自动滚动，避免流式时抢走用户的上翻阅读位置。
    @State private var stickToBottom = true
    @State private var lastStreamScroll = Date.distantPast

    private static let bottomTolerance: CGFloat = 40
    private static let streamScrollInterval: TimeInterval = 1.0 / 12.0

    private var session: ChatSession? {
        selectedID.flatMap { sessionStore.session(id: $0) }
    }

    private var streamingMessageID: UUID? {
        guard let state = streamingState, streamingSessionID == session?.id else { return nil }
        return state.id
    }

    /// 流式分片发布器：只观察当前正在流式的那条消息，收到分片仅刷新该行。
    private var streamingTick: AnyPublisher<Void, Never> {
        guard let state = streamingState, streamingSessionID == session?.id else {
            return Empty().eraseToAnyPublisher()
        }
        return state.objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    var body: some View {
        VStack(spacing: 0) {
            DragHandleStrip()
            header

            if !settings.keyConfigured {
                noticeBar
            }

            messagesArea
            composer
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("显示 / 隐藏会话列表")

            Text(session?.title.isEmpty == false ? session!.title : "新对话")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(session?.messages.count ?? 0) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var noticeBar: some View {
        HStack {
            Text("尚未配置 DeepSeek API Key")
                .font(.caption)
            Spacer()
            Button("去设置") { onOpenSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    // MARK: - 消息区

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChatTopOffsetKey.self,
                        value: geo.frame(in: .named("chatScroll")).minY
                    )
                }
                .frame(height: 0)

                if let messages = session?.messages, !messages.isEmpty {
                    // 倒置聊天列表（聊天类应用的业界标准做法）：
                    // 消息按倒序渲染，容器与每行各旋转 180°（双重旋转，文本与
                    // 选区恢复正向）。新消息出现在视觉底部，贴底时只需滚动到
                    // 最新一条——它就在视口旁边、必然已物化，绕开了
                    // “LazyVStack 程序化滚动到未物化区域 → 空白”的已知缺陷，
                    // 同时保持 LazyVStack 懒加载（不引入 VStack 全量布局的卡顿）。
                    LazyVStack(spacing: 10) {
                        ForEach(messages.reversed()) { message in
                            MessageView(
                                state: sessionStore.messageState(for: message),
                                isStreaming: message.id == streamingMessageID
                            )
                            .rotationEffect(.degrees(180))
                        }
                    }
                    .padding(.vertical, 10)
                    .rotationEffect(.degrees(180))
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ChatContentHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                } else {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .coordinateSpace(name: "chatScroll")
            .defaultScrollAnchor(.bottom)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChatViewportHeightKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onPreferenceChange(ChatTopOffsetKey.self) {
                topOffset = $0
                scheduleStickToBottomUpdate()
            }
            .onPreferenceChange(ChatContentHeightKey.self) {
                contentHeight = $0
                scheduleStickToBottomUpdate()
            }
            .onPreferenceChange(ChatViewportHeightKey.self) {
                viewportHeight = $0
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: selectedID) { _, _ in
                stickToBottom = true
                scrollToBottom(proxy)
            }
            .onChange(of: session?.messages.count) { _, _ in
                if stickToBottom {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: streamingMessageID) { _, newValue in
                guard streamingSessionID == session?.id else { return }
                if newValue != nil {
                    stickToBottom = true
                    scrollToBottom(proxy)
                } else if stickToBottom {
                    scrollToBottom(proxy)
                }
            }
            .onReceive(streamingTick) { _ in
                handleStreamingScroll(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("DeepSeek Chat")
                .font(.title2)
                .fontWeight(.semibold)
            Text("开始一段新的对话")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("新建对话") {
                let created = sessionStore.createSession()
                selectedID = created.id
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let newest = session?.messages.last else { return }
        let targetID = newest.id
        // 倒置布局下，最新一条消息位于视觉底部；贴底时它就在视口旁，
        // 必然已物化，滚动可靠且不会落到空白区域。
        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: .bottom)
        }
    }

    /// 流式期间的即时滚动：仅贴底时执行，节流到约 12 次/秒，不使用动画。
    private func handleStreamingScroll(_ proxy: ScrollViewProxy) {
        guard stickToBottom else { return }
        guard let newest = session?.messages.last else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStreamScroll) >= Self.streamScrollInterval else { return }
        lastStreamScroll = now
        proxy.scrollTo(newest.id, anchor: .bottom)
    }

    /// 下一轮 RunLoop 重新评估“是否贴底”。
    /// 同一帧里顶部偏移与底部锚点的 preference 更新顺序不固定，
    /// 异步汇总后再判断，避免读到半新半旧的数据。
    private func scheduleStickToBottomUpdate() {
        DispatchQueue.main.async {
            self.recomputeStickToBottom()
        }
    }

    private func recomputeStickToBottom() {
        guard let last = lastTopOffset else {
            lastTopOffset = topOffset
            return
        }
        // 顶部偏移没变 = 内容增长（流式追加）或重复布局，不改变贴底状态。
        guard last != topOffset else { return }
        lastTopOffset = topOffset
        // 倒置布局：内容起点（最新消息端）贴近视口底部 ⇔ 用户位于底部。
        let maxOffset = max(0, contentHeight - viewportHeight)
        stickToBottom = -topOffset >= maxOffset - Self.bottomTolerance
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息，Enter 发送，Option + Enter 换行", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { send() }

                if streamingSessionID != nil {
                    Button(action: stop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("停止生成")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !settings.keyConfigured
                    )
                    .help("发送")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2))
            )

            Text("内容由 DeepSeek AI 生成，请甄别使用")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    // MARK: - 发送 / 停止

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, streamingSessionID == nil, settings.keyConfigured else { return }

        var targetID = selectedID
        var targetSession = targetID.flatMap { sessionStore.session(id: $0) }
        if targetSession == nil {
            let created = sessionStore.createSession()
            targetSession = created
            targetID = created.id
            selectedID = created.id
        }
        guard let session = targetSession, let sessionID = targetID else { return }

        draft = ""
        if session.messages.isEmpty {
            sessionStore.renameSession(id: sessionID, title: String(text.prefix(30)))
        }
        let userMessage = ChatMessage(role: .user, content: text)
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            isSearching: settings.webSearch
        )
        sessionStore.appendMessage(sessionID: sessionID, userMessage)
        sessionStore.appendMessage(sessionID: sessionID, assistantMessage)
        let assistantState = sessionStore.messageState(for: assistantMessage)

        let history = sessionStore.history(for: sessionID)
        streamingSessionID = sessionID
        streamingState = assistantState

        streamTask?.cancel()
        streamTask = Task { [weak sessionStore] in
            guard let sessionStore else { return }
            await runStream(
                sessionStore: sessionStore,
                sessionID: sessionID,
                state: assistantState,
                history: history
            )
            // 收尾清理前先确认流式状态仍属于本任务：
            // 用户停止后旧任务可能仍在异步收尾，此时若已发起新一轮流式，
            // 直接清 nil 会把新任务的流式状态覆盖掉，导致新回复失去
            // isStreaming 标记 → 走最终 Markdown 路径 → 每分片全文重解析 → 长回复卡死空白。
            if streamingSessionID == sessionID, streamingState === assistantState {
                streamingSessionID = nil
                streamingState = nil
            }
        }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        streamingState?.isSearching = false
        streamingSessionID = nil
        streamingState = nil
    }

    @MainActor
    private func runStream(
        sessionStore: SessionStore,
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

        let client = DeepSeekClient(apiKey: settings.apiKey)
        let model = settings.model
        let canSearch = settings.webSearch && ModelInfo.info(model).supportsResponses

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
                    callbacks: callbacks
                )
            } else {
                try await client.chatCompletions(
                    model: model,
                    messages: history,
                    thinking: settings.thinking,
                    effort: settings.effort,
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
