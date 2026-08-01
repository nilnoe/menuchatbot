import XCTest

@testable import DeepSeekChat

/// 性能基线（XCTMeasure）：给关键路径留档，防止回归。
///
/// 基线数值由 Xcode 记录（Edit Scheme → Test → Metrics 里查看 / 更新），
/// CI 只保证这些测量能跑通；若某个路径出现数量级劣化，与历史基线对比即可发现。
final class PerformanceBaselineTests: XCTestCase {
    /// 生成带标题 / 列表 / 代码块 / 引用的长 Markdown 文档，模拟长回复。
    private func makeLongMarkdown(paragraphs: Int) -> String {
        var parts: [String] = []
        for index in 0..<paragraphs {
            parts.append(
                """
                ## 第 \(index) 节

                正文段落，包含 **加粗**、*斜体*、[链接](https://example.com/\(index)) 与 `行内代码`。

                - 列表项 A
                - 列表项 B

                ```swift
                func sum(_ values: [Int]) -> Int {
                    return values.reduce(0, +)
                }
                ```

                > 引用块内容

                """)
        }
        return parts.joined(separator: "\n")
    }

    func testMarkdownParseThroughput() {
        let text = makeLongMarkdown(paragraphs: 80)
        measure {
            for _ in 0..<20 {
                _ = MarkdownCache.content(for: text)
            }
        }
    }

    func testSSEParserThroughput() {
        let line = #"data: {"choices":[{"delta":{"content":"x"}}]}"#
        measure {
            for _ in 0..<500 {
                guard
                    let payload = SSEParser.payload(fromLine: line),
                    let data = payload.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                SSEParser.process(
                    json,
                    kind: .chat,
                    callbacks: StreamCallbacks(onDelta: { _ in })
                )
            }
        }
    }

    func testMessageStateFlushThroughput() {
        measure {
            let state = MessageState(message: ChatMessage(role: .assistant, content: ""))
            for _ in 0..<1_000 {
                state.appendContent("x")
                state.flushPending()
            }
        }
    }
}
