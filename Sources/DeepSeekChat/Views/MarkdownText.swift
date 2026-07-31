import SwiftUI

/// 基于 AttributedString(markdown:) 的轻量 Markdown 渲染
struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(attributedString)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedString: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)

        for run in attributed.runs {
            if run.link != nil {
                attributed[run.range].foregroundColor = Color(nsColor: .linkColor)
            }
        }
        return attributed
    }
}
