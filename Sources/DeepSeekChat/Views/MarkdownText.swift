import MarkdownUI
import SwiftUI

/// 基于 MarkdownUI（gonzalezreal/MarkdownUI）的 Markdown 渲染。
///
/// 流式期间也实时渲染 Markdown，但按 ~250ms 节流（约 4fps）：
/// 既能看到实时格式，又避免每个 token 都对累积全文重新解析/排版。
/// 回复结束后按最终内容再渲染一次（`MarkdownContent` 按内容缓存，复用不重解析）。
struct MarkdownText: View {
    let text: String
    var isStreaming: Bool = false

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
                    .markdownTheme(.basic)
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
                .markdownTheme(.basic)
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

/// Markdown 解析结果缓存：同一内容只解析一次。
/// 流式期间不会进入缓存，因此缓存里只有最终版本，内存占用有上限。
enum MarkdownCache {
    private static var cache: [String: MarkdownContent] = [:]
    private static var totalCharacters = 0
    private static let maxEntries = 100
    private static let maxTotalCharacters = 2_000_000

    static func content(for text: String) -> MarkdownContent {
        if let cached = cache[text] {
            return cached
        }

        let content = MarkdownContent(text)

        if cache.count >= maxEntries || totalCharacters + text.count > maxTotalCharacters {
            cache.removeAll(keepingCapacity: true)
            totalCharacters = 0
        }
        cache[text] = content
        totalCharacters += text.count
        return content
    }
}
