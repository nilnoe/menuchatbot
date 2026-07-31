import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 48)
            } else {
                avatar
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    reasoningGroup(reasoning)
                }
                if message.isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在联网搜索…")
                            .font(.caption)
                    }
                    .foregroundStyle(.tint)
                }
                contentView
                if let sources = message.sources, !sources.isEmpty {
                    sourcesView(sources)
                }
            }
            .padding(10)
            .frame(maxWidth: 720, alignment: message.role == .user ? .trailing : .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        message.role == .user
                            ? Color.accentColor.opacity(0.85)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            if message.role == .assistant {
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
        if message.isError {
            Text(message.content)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if !message.content.isEmpty {
            if message.role == .user {
                Text(message.content)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            } else {
                MarkdownText(text: message.content)
            }
        } else if isStreaming && !message.isSearching {
            ProgressView()
                .controlSize(.small)
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
                Link(
                    source.title?.isEmpty == false ? source.title! : source.url,
                    destination: URL(string: source.url)!
                )
                .font(.caption)
                .lineLimit(1)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
