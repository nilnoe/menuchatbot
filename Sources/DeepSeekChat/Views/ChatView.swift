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
    @EnvironmentObject var controller: ChatStreamController

    @Binding var selectedID: UUID?
    var onOpenSettings: () -> Void
    var onToggleSidebar: () -> Void

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
        guard let state = controller.streamingState,
            controller.streamingSessionID == session?.id
        else { return nil }
        return state.id
    }

    /// 流式分片发布器：只观察当前正在流式的那条消息，收到分片仅刷新该行。
    private var streamingTick: AnyPublisher<Void, Never> {
        guard let state = controller.streamingState,
            controller.streamingSessionID == session?.id
        else {
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

                if let session, !session.messages.isEmpty {
                    // 倒置聊天列表（聊天类应用的业界标准做法）：
                    // 消息按倒序渲染，容器与每行各旋转 180°（双重旋转，文本与
                    // 选区恢复正向）。新消息出现在视觉底部，贴底时只需滚动到
                    // 最新一条——它就在视口旁边、必然已物化，绕开了
                    // “LazyVStack 程序化滚动到未物化区域 → 空白”的已知缺陷，
                    // 同时保持 LazyVStack 懒加载（不引入 VStack 全量布局的卡顿）。
                    LazyVStack(spacing: 10) {
                        ForEach(session.messages.reversed()) { message in
                            let canRetry =
                                message.isError
                                && message.id == session.messages.last?.id
                            MessageView(
                                state: sessionStore.messageState(for: message),
                                isStreaming: message.id == streamingMessageID,
                                modelLabel: ModelInfo.info(settings.model).shortName,
                                onRetry: canRetry
                                    ? { controller.retryLastExchange(in: session.id) } : nil
                            )
                            .rotationEffect(.degrees(180))
                        }
                    }
                    .padding(.vertical, 10)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ChatContentHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .frame(maxWidth: DesignTokens.messageMaxWidth)
                    .frame(maxWidth: .infinity)
                    // 短会话顶置：旋转前把内容对齐到最小高度框的底部，
                    // 旋转 180° 后正好落在视觉顶部（新消息仍在底部逐条向下增长）。
                    // 内容超过视口后 minHeight 失效，行为与原来一致（贴底跟随）。
                    .frame(minHeight: viewportHeight, alignment: .bottom)
                    .rotationEffect(.degrees(180))
                } else {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .coordinateSpace(name: "chatScroll")
            .defaultScrollAnchor(.bottom)
            // 倒置列表下滚动条会镜像到另一侧、拖动方向相反，隐藏它更贴近
            // 聊天应用惯例（Messages 等也常隐藏）；滚动仍可用触控板/滚轮。
            .scrollIndicators(.hidden)
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
                guard controller.streamingSessionID == session?.id else { return }
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

            HStack(spacing: 8) {
                ForEach(Self.suggestionPrompts, id: \.self) { prompt in
                    Button(prompt) {
                        send(prompt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!settings.keyConfigured)
                }
            }
            .padding(.top, 8)
        }
    }

    private static let suggestionPrompts = [
        "帮我写周报",
        "解释这段代码",
        "写一封请假邮件",
        "推荐周末活动",
    ]

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
                TextField(
                    "输入消息，Enter 发送，Option + Enter 换行", text: $controller.draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { send() }

                if controller.streamingSessionID != nil {
                    Button(action: controller.stop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("停止生成")
                } else {
                    Button(action: { send() }) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    .stroke(
                        inputFocused
                            ? Color.accentColor.opacity(0.7)
                            : Color.secondary.opacity(0.2),
                        lineWidth: inputFocused ? 1.5 : 1
                    )
            )

            Text("内容由 DeepSeek AI 生成，请甄别使用")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    // MARK: - 发送（薄壳：业务在 ChatStreamController）

    private func send(_ preset: String? = nil) {
        if let created = controller.send(preset, selectedSessionID: selectedID) {
            selectedID = created
        }
    }
}
