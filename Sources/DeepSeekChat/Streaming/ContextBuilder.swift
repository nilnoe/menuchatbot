import Foundation

/// token 估算协议：本地暂无真实 tokenizer，先用字符启发式；
/// Tier 3 接入 embedding 后可替换为更精确实现，调用方不受影响。
protocol TokenEstimating {
    func estimateTokens(_ text: String) -> Int
}

/// 启发式估算：CJK（含假名 / 谚文）按 1 字符 ≈ 1 token，
/// 其余按 4 字符 ≈ 1 token。仅用于预算控制，不用于计费。
struct CharacterTokenEstimator: TokenEstimating {
    func estimateTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return cjk + (other + 3) / 4
    }

    private func isCJK(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return
            (0x4E00...0x9FFF).contains(value)  // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(value)  // 扩展 A
            || (0xF900...0xFAFF).contains(value)  // 兼容表意文字
            || (0x3040...0x30FF).contains(value)  // 假名
            || (0xAC00...0xD7AF).contains(value)  // 谚文
    }
}

/// 统一上下文预算入口（Tier 1 第二批）：历史截断 / RAG 注入 / 工具结果
/// 记账都必须经过本类型，禁止各模块自行拼上下文（ADR-0008 D3）。
struct ContextBuilder {
    /// 默认发送给 API 的历史 token 预算（可随设置扩展）。
    static let defaultTokenBudget = 32_768

    var estimator: TokenEstimating = CharacterTokenEstimator()

    /// 构建历史：在预算内保留尽量多的**最近**消息；永不丢弃最后一条消息
    /// （发送场景即最新用户问题），保证请求语义完整。
    func buildHistory(
        _ messages: [APIMessage],
        tokenBudget: Int = ContextBuilder.defaultTokenBudget
    ) -> [APIMessage] {
        guard !messages.isEmpty else { return [] }
        var startIndex = 0
        while startIndex < messages.count - 1,
            estimateTotal(messages[startIndex...]) > tokenBudget
        {
            startIndex += 1
        }
        return Array(messages[startIndex...])
    }

    /// 单条消息的估算：content + 角色 / 分隔符开销。
    func estimate(_ message: APIMessage) -> Int {
        estimator.estimateTokens(message.content) + 4
    }

    private func estimateTotal<S: Sequence>(_ messages: S) -> Int where S.Element == APIMessage {
        messages.reduce(0) { $0 + estimate($1) }
    }
}
