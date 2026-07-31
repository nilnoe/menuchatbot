import MarkdownUI
import SwiftUI

/// 聊天场景的 Markdown 主题：中文排版优化 + 代码块卡片（语言标签 + 复制按钮）。
///
/// 基于 MarkdownUI 官方 `Theme.basic` 微调，代码块走官方 `codeBlock` 扩展点
/// 自定义容器视图，复用库的高亮与解析能力。
enum ChatMarkdownTheme {
    static let chat: Theme = Theme.basic
        .codeBlock { configuration in
            CodeBlockCard(
                language: configuration.language,
                content: configuration.content,
                label: configuration.label
            )
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.6))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.45))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.5))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.4))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.8), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                }
        }
        .blockquote { configuration in
            configuration.label
                .relativePadding(.leading, length: .em(0.8))
                .markdownMargin(top: .zero, bottom: .em(0.7))
                .markdownTextStyle {
                    FontStyle(.italic)
                    ForegroundColor(.secondary)
                }
        }
}

/// 代码块卡片：顶部语言标签 + 复制按钮，正文为官方高亮后的 label。
private struct CodeBlockCard: View {
    let language: String?
    let content: String
    let label: CodeBlockConfiguration.Label

    @State private var copied = false

    private var languageLabel: String {
        guard let language, !language.isEmpty else { return "text" }
        switch language.lowercased() {
        case "plaintext", "plain": return "text"
        default: return language
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel)
                    .font(
                        .system(
                            size: DesignTokens.FontSize.caption, weight: .medium,
                            design: .monospaced)
                    )
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: DesignTokens.FontSize.caption))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .disabled(copied)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            ScrollView(.horizontal, showsIndicators: false) {
                label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(DesignTokens.Spacing.md)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
        .markdownMargin(top: .zero, bottom: .em(1))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) {
            copied = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.15)) {
                copied = false
            }
        }
    }
}

/// 基于 MarkdownUI（gonzalezreal/MarkdownUI）的 Markdown 渲染。
///
/// 流式期间也实时渲染 Markdown，但按 ~250ms 节流（约 4fps）：
/// 既能看到实时格式，又避免每个 token 都对累积全文重新解析/排版。
/// 回复结束后按最终内容再渲染一次（`MarkdownContent` 按内容缓存，复用不重解析）。
struct MarkdownText: View {
    let text: String
    var isStreaming: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// 流式期间最近一次已渲染的解析结果（节流显示用）。
    @State private var liveContent: MarkdownContent?
    @State private var lastLiveRender = Date.distantPast

    private static let liveRenderInterval: TimeInterval = 0.25

    var body: some View {
        Group {
            if isStreaming {
                liveMarkdown
            } else {
                Markdown(MarkdownCache.content(for: text))
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .markdownTheme(ChatMarkdownTheme.chat)
                    .markdownCodeSyntaxHighlighter(CodeHighlighters.highlighter(for: colorScheme))
                    .markdownTextStyle(\.link) {
                        ForegroundColor(Color(nsColor: .linkColor))
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text) { _, newValue in
            guard isStreaming else { return }
            let now = Date()
            guard now.timeIntervalSince(lastLiveRender) >= Self.liveRenderInterval else { return }
            lastLiveRender = now
            liveContent = MarkdownCache.content(for: newValue)
        }
    }

    /// 流式快速路径：显示最近一次节流渲染的 Markdown；
    /// 尚未解析过时退回纯文本（第一次分片到达后立即解析）。
    @ViewBuilder
    private var liveMarkdown: some View {
        if let content = liveContent {
            Markdown(content)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .markdownTheme(ChatMarkdownTheme.chat)
                // 流式期间用纯文本高亮器：每 250ms 全文重渲染时不再额外跑
                // 高亮 JS，避免长代码块 O(n²)；最终版本在非流式路径一次高亮并缓存。
                .markdownCodeSyntaxHighlighter(.plainText)
                .markdownTextStyle(\.link) {
                    ForegroundColor(Color(nsColor: .linkColor))
                }
        } else {
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
        }
    }
}
