import Foundation
import MarkdownUI
import XCTest

@testable import DeepSeekChat

final class MarkdownCacheTests: XCTestCase {
    func testRepeatedLookupReturnsStableResult() {
        let text = "# 标题\n\n正文 **加粗** 与 [链接](https://example.com)"
        let first = MarkdownCache.content(for: text)
        let second = MarkdownCache.content(for: text)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.renderPlainText().isEmpty)
    }

    func testDistinctContentsDoNotShareCache() {
        let a = MarkdownCache.content(for: "内容 A")
        let b = MarkdownCache.content(for: "内容 B")
        XCTAssertNotEqual(a, b)
    }

    func testStreamingFastPathTextIsPlain() {
        // 流式标记下直接走 Text(text)，不进入缓存；验证视图能正常构造。
        let view = MarkdownText(text: "**未解析**", isStreaming: true)
        XCTAssertFalse(view.text.isEmpty)
    }
}
