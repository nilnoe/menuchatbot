import Foundation
import MarkdownUI

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
