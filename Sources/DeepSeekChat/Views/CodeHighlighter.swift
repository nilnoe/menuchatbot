import Highlighter
import MarkdownUI
import SwiftUI

/// MarkdownUI `CodeSyntaxHighlighter` 的 HighlighterSwift 实现。
///
/// 复用开源库 HighlighterSwift（内部是 highlight.js 11，185+ 语言、自动检测），
/// 不自己写分词器。高亮结果按（语言, 内容）缓存，同一代码块只执行一次 JS；
/// 缓存有上限，防止长会话里代码块累积撑爆内存。
///
/// 线程约定：`Highlighter` 内部持有 JSContext，仅允许主线程调用；
/// MarkdownUI 的 `highlightCode` 在视图更新期间（主线程）调用，符合要求。
struct HighlighterCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let box: HighlighterBox

    init(theme: String) {
        box = CodeHighlighters.box(theme: theme)
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let highlighted = box.highlight(code, language: language) else {
            return Text(code)
        }
        return Text(highlighted)
    }
}

/// 按主题复用一个 `Highlighter` 实例（初始化要加载 JS 与主题，开销不小）。
enum CodeHighlighters {
    /// 明暗两套主题：跟随系统外观。
    static func highlighter(for scheme: ColorScheme) -> CodeSyntaxHighlighter {
        let theme = scheme == .dark ? "atom-one-dark" : "atom-one-light"
        return HighlighterCodeSyntaxHighlighter(theme: theme)
    }

    static func box(theme: String) -> HighlighterBox {
        if let box = boxes[theme] {
            return box
        }
        let box = HighlighterBox(theme: theme)
        boxes[theme] = box
        return box
    }

    private static var boxes: [String: HighlighterBox] = [:]
}

/// 持有一个高亮引擎与结果缓存。
final class HighlighterBox {
    static let empty = HighlighterBox(engine: nil)

    private let engine: Highlighter?
    private var cache: [String: AttributedString] = [:]
    private var totalCharacters = 0

    private static let maxEntries = 200
    private static let maxTotalCharacters = 4_000_000
    /// 超长代码块跳过高亮（高亮 JS 对超大输入耗时且收益低）。
    private static let maxCodeLength = 100_000

    init(theme: String) {
        guard let highlighter = Highlighter(),
            highlighter.setTheme(theme, withFont: "SFMono-Regular", ofSize: 13)
        else {
            engine = nil
            return
        }
        highlighter.theme.setCodeFont(.monospacedSystemFont(ofSize: 13, weight: .regular))
        engine = highlighter
    }

    private init(engine: Highlighter?) {
        self.engine = engine
    }

    func highlight(_ code: String, language: String?) -> AttributedString? {
        guard let engine else { return nil }
        guard code.count <= Self.maxCodeLength else { return nil }

        // 空语言交给 highlight.js 自动检测；不支持的语言返回 nil 时走纯文本兜底。
        let normalizedLanguage = language?.isEmpty == false ? language : nil
        let key = (normalizedLanguage ?? "") + "\u{0}" + code
        if let cached = cache[key] {
            return cached
        }
        guard let result = engine.highlight(code, as: normalizedLanguage) else {
            return nil
        }

        let attributed = AttributedString(result)
        if cache.count >= Self.maxEntries || totalCharacters + code.count > Self.maxTotalCharacters
        {
            cache.removeAll(keepingCapacity: true)
            totalCharacters = 0
        }
        cache[key] = attributed
        totalCharacters += code.count
        return attributed
    }
}
