import SwiftUI

struct ChatView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var settings: SettingsStore

    @Binding var selectedID: UUID?
    var onOpenSettings: () -> Void
    var onToggleSidebar: () -> Void

    @State private var draft = ""
    @State private var streamingSessionID: UUID?
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private var session: ChatSession? {
        selectedID.flatMap { sessionStore.session(id: $0) }
    }

    private var streamingMessageID: UUID? {
        guard let id = streamingSessionID, id == session?.id,
              let last = session?.messages.last else { return nil }
        return last.id
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
                LazyVStack(spacing: 10) {
                    if let messages = session?.messages, !messages.isEmpty {
                        ForEach(messages) { message in
                            MessageView(
                                message: message,
                                isStreaming: message.id == streamingMessageID
                            )
                        }
                    } else {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: session?.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: session?.messages.last?.content) { _, _ in
                scrollToBottom(proxy)
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
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
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

        let history = sessionStore.history(for: sessionID)
        streamingSessionID = sessionID

        streamTask?.cancel()
        streamTask = Task { [weak sessionStore] in
            guard let sessionStore else { return }
            await runStream(
                sessionStore: sessionStore,
                sessionID: sessionID,
                messageID: assistantMessage.id,
                history: history
            )
            if !Task.isCancelled {
                streamingSessionID = nil
            }
        }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        if let messageID = streamingMessageID {
            sessionStore.updateMessage(sessionID: selectedID!, messageID: messageID) {
                $0.isSearching = false
            }
        }
        streamingSessionID = nil
    }

    @MainActor
    private func runStream(
        sessionStore: SessionStore,
        sessionID: UUID,
        messageID: UUID,
        history: [APIMessage]
    ) async {
        let client = DeepSeekClient(apiKey: settings.apiKey)
        let model = settings.model
        let canSearch = settings.webSearch && ModelInfo.info(model).supportsResponses

        let callbacks = StreamCallbacks(
            onDelta: { chunk in
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.content += chunk
                }
            },
            onReasoning: { chunk in
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.reasoning = ($0.reasoning ?? "") + chunk
                }
            },
            onSearching: {
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.isSearching = true
                }
            },
            onSources: { sources in
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.sources = sources
                    $0.isSearching = false
                }
            },
            onDone: {
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.isSearching = false
                }
            },
            onError: { message in
                sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                    $0.content = message
                    $0.isSearching = false
                    $0.isError = true
                }
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
            sessionStore.updateMessage(sessionID: sessionID, messageID: messageID) {
                $0.content = error.localizedDescription
                $0.isError = true
                $0.isSearching = false
            }
        }
    }
}
