import SwiftUI

struct MessageView: View {
    @ObservedObject var state: MessageState
    let isStreaming: Bool

    /// 单条消息超过该字数时默认截断显示（避免超长 Text 全文排版卡顿），可展开。
    private static let longMessageLimit = 20_000
    @State private var expanded = false

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
                avatar
            }

            VStack(alignment: state.role == .user ? .trailing : .leading, spacing: 6) {
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
            }
            .padding(10)
            .frame(maxWidth: 720, alignment: state.role == .user ? .trailing : .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        state.role == .user
                            ? Color.accentColor.opacity(0.85)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            if state.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .padding(.horizontal, 12)
    }

    private var avatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(
                LinearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }

    @ViewBuilder
    private var contentView: some View {
        if state.isError {
            Text(state.content)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
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
        let displayText = truncated
            ? String(state.content.prefix(Self.longMessageLimit))
            : state.content
        return VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: displayText, isStreaming: effectiveStreaming)
            if truncated {
                Button {
                    expanded = true
                } label: {
                    Text("展开全部 · 共 \(total) 字")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reasoningGroup(_ reasoning: String) -> some View {
        DisclosureGroup {
            Text(reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("思考过程")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func sourcesView(_ sources: [Source]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("参考来源")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                if let url = URL(string: source.url) {
                    Link(
                        source.title?.isEmpty == false ? source.title! : source.url,
                        destination: url
                    )
                    .font(.caption)
                    .lineLimit(1)
                } else {
                    Text(source.title?.isEmpty == false ? source.title! : source.url)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
