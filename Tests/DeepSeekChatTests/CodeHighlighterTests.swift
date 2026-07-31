import XCTest

@testable import DeepSeekChat

final class CodeHighlighterTests: XCTestCase {
    func testHighlightsSwiftCodeBlock() {
        let box = HighlighterBox(theme: "atom-one-dark")
        let code = "let answer = 42\nprint(answer)"
        let result = box.highlight(code, language: "swift")

        XCTAssertNotNil(result, "Highlighter 应能高亮 Swift 代码")
        XCTAssertEqual(
            result?.characters.map(String.init).joined(),
            code,
            "高亮结果必须保留原始代码内容"
        )
    }

    func testAutoDetectsLanguageWhenNil() {
        let box = HighlighterBox(theme: "atom-one-light")
        let result = box.highlight("def hello():\n    return 1", language: nil)
        XCTAssertNotNil(result, "未指定语言时应走 highlight.js 自动检测")
    }

    func testUnknownLanguageFallsBackGracefully() {
        let box = HighlighterBox(theme: "atom-one-dark")
        // 不存在的语言：库可能自动检测或返回 nil，两者都不应抛错。
        _ = box.highlight("let x = 1", language: "definitely-not-a-language")
    }

    func testInvalidThemeFallsBackToNil() {
        let box = HighlighterBox(theme: "no-such-theme")
        XCTAssertNil(box.highlight("let x = 1", language: "swift"))
    }

    func testResultCachedAcrossCalls() {
        let box = HighlighterBox(theme: "atom-one-dark")
        let code = "func add(_ a: Int, _ b: Int) -> Int { a + b }"
        let first = box.highlight(code, language: "swift")
        let second = box.highlight(code, language: "swift")

        XCTAssertNotNil(first)
        XCTAssertEqual(
            first?.characters.map(String.init).joined(),
            second?.characters.map(String.init).joined()
        )
    }

    func testOversizedCodeBlockSkipped() {
        let box = HighlighterBox(theme: "atom-one-dark")
        let code = String(repeating: "let x = 1\n", count: 30_000)
        XCTAssertGreaterThan(code.count, 100_000)
        XCTAssertNil(box.highlight(code, language: "swift"))
    }
}
