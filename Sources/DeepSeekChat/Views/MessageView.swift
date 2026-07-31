import SwiftUI

struct MessageView: View {
    @ObservedObject var state: MessageState
    let isStreaming: Bool
    /// assistant 消息的模型短标签（如 "V4 Flash"）。
    var modelLabel: String? = nil
    /// 当前模型信息（含官方单价）；nil 时用量行不显示费用估算。
    var modelInfo: ModelInfo? = nil
    /// 错误消息上的重试动作（仅在错误消息是会话末尾时由 ChatView 注入）。
    var onRetry: (() -> Void)? = nil

    /// 单条消息超过该字数时默认截断显示（避免超长 Text 全文排版卡顿），可展开。
    private static let longMessageLimit = 20_000
    @State private var expanded = false
    @State private var appeared = false

    /// 行内实际流式状态：外部标记或消息自身标记任一为真即按流式渲染。
    /// 外部状态可能被旧任务收尾误清，消息自身标记保证长输出仍走节流实时路径。
    private var effectiveStreaming: Bool {
        isStreaming || state.isStreaming
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if state.role == .user {
                Spacer(minLength: 48)
            } else {
                assistantAvatar
            }

            VStack(alignment: state.role == .user ? .trailing : .leading, spacing: 6) {
                if state.role == .assistant, let modelLabel {
                    modelBadge(modelLabel)
                }
                if let reasoning = state.reasoning, !reasoning.isEmpty {
                    reasoningGroup(reasoning)
                }
                if state.isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在联网搜索…")
                            .font(.caption)
                    }
                    .foregroundStyle(.tint)
                }
                contentView
                if let sources = state.sources, !sources.isEmpty {
                    sourcesView(sources)
                }
                if state.role == .assistant, let usage = state.usage {
                    usageLine(usage)
                }
                timestamp
            }
            .padding(DesignTokens.Spacing.md - 2)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                    .fill(bubbleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                    .stroke(bubbleStroke, lineWidth: 1)
            )
            .contextMenu {
                Button("复制纯文本") { copyPlainText() }
                Button("复制 Markdown") { copyMarkdown() }
                if state.isError, onRetry != nil {
                    Divider()
                    Button("重试") { onRetry?() }
                }
            }

            if state.role == .assistant {
                Spacer(minLength: 48)
            } else {
                userAvatar
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        // 行级限宽：限制整行宽度（而非气泡），气泡在行内贴合文字，
        // 长文本在限宽内换行。详见 DesignTokens 的注释。
        .frame(
            maxWidth: state.role == .user
                ? DesignTokens.userBubbleMaxWidth
                : DesignTokens.assistantBubbleMaxWidth,
            alignment: state.role == .user ? .trailing : .leading
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) {
                appeared = true
            }
        }
    }

    private var bubbleFill: Color {
        if state.isError {
            return Color.red.opacity(0.06)
        }
        return state.role == .user
            ? Color.accentColor
            : Color(nsColor: .controlBackgroundColor)
    }

    private var bubbleStroke: Color {
        state.isError ? Color.red.opacity(0.3) : Color.secondary.opacity(0.12)
    }

    private var assistantAvatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: DesignTokens.FontSize.caption + 2))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(
                DesignTokens.brandGradient,
                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm + 2)
            )
    }

    private var userAvatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 24))
            .foregroundStyle(Color.secondary.opacity(0.55))
    }

    private func modelBadge(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text(label)
        }
        .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var timestamp: some View {
        Text(state.createdAt.formatted(date: .omitted, time: .shortened))
            .font(.system(size: DesignTokens.FontSize.caption - 1))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private func usageLine(_ usage: TokenUsage) -> some View {
        var text =
            "输入 \(TokenUsage.compact(usage.promptTokens)) · 输出 \(TokenUsage.compact(usage.completionTokens))"
        if let modelInfo,
            let inputPrice = modelInfo.inputPricePerMillion,
            let outputPrice = modelInfo.outputPricePerMillion
        {
            let cost = usage.estimatedCost(
                inputPricePerMillion: inputPrice,
                cachedInputPricePerMillion: modelInfo.cachedInputPricePerMillion,
                outputPricePerMillion: outputPrice
            )
            text += " · ≈$\(String(format: "%.4f", cost))"
        }
        return HStack(spacing: 4) {
            Image(systemName: "chart.bar")
                .font(.system(size: 9))
            Text(text)
        }
        .font(.system(size: DesignTokens.FontSize.caption - 1))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var contentView: some View {
        if state.isError {
            VStack(alignment: .leading, spacing: 8) {
                Label("出错了", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignTokens.FontSize.caption, weight: .semibold))
                    .foregroundStyle(.red)
                Text(state.content)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !state.content.isEmpty {
            if state.role == .user {
                Text(state.content)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            } else {
                assistantContent
            }
        } else if effectiveStreaming && !state.isSearching {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var assistantContent: some View {
        let total = state.content.count
        let truncated = total > Self.longMessageLimit && !expanded
        let displayText =
            truncated
            ? String(state.content.prefix(Self.longMessageLimit))
            : state.content
        return VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: displayText, isStreaming: effectiveStreaming)
            if truncated {
                Button {
                    expanded = true
                } label: {
                    Text("展开全部 · 共 \(total) 字")
                        .font(.system(size: DesignTokens.FontSize.caption))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reasoningGroup(_ reasoning: String) -> some View {
        DisclosureGroup {
            Text(reasoning)
                .font(.system(size: DesignTokens.FontSize.caption))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("思考过程", systemImage: "brain.head.profile")
                .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private func sourcesView(_ sources: [Source]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("参考来源 · \(sources.count)", systemImage: "link")
                .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        sourceRow(source)
                    }
                    .buttonStyle(.plain)
                } else {
                    sourceRow(source)
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceRow(_ source: Source) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title?.isEmpty == false ? source.title! : source.url)
                    .font(.system(size: DesignTokens.FontSize.caption))
                    .lineLimit(1)
                if let url = URL(string: source.url) {
                    Text(url.host() ?? source.url)
                        .font(.system(size: DesignTokens.FontSize.caption - 1))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - 复制

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.content, forType: .string)
    }

    /// 纯文本提取复用系统 NSAttributedString(markdown:) 能力，不自己写解析器。
    private func copyPlainText() {
        let plain =
            (try? AttributedString(
                markdown: state.content,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ))?.characters.map(String.init).joined() ?? state.content
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }
}
