import Foundation

/// 一次 API 调用的 token 用量统计。
///
/// - 输入（prompt）：流式 Chat Completions 通过 `stream_options.include_usage`
///   在收尾块携带；Responses API 在 `response.completed` 事件中携带。
/// - 缓存命中（cached）：DeepSeek 返回 `prompt_cache_hit_tokens`（Chat
///   Completions）或 `input_tokens_details.cached_tokens`（Responses），
///   费用估算按命中/未命中单价分开计算。
struct TokenUsage: Codable, Equatable {
    var promptTokens: Int
    var cachedTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    /// 按官方单价（USD / 1M tokens）估算本次调用费用；价格未知返回 nil。
    /// 缓存命中输入按命中单价计，其余输入按未命中单价计。
    func estimatedCost(
        inputPricePerMillion: Double,
        cachedInputPricePerMillion: Double?,
        outputPricePerMillion: Double
    ) -> Double {
        let cachedInput = Double(min(cachedTokens, promptTokens))
        let missInput = Double(promptTokens) - cachedInput
        let cachedPrice = cachedInputPricePerMillion ?? inputPricePerMillion
        return
            (missInput * inputPricePerMillion + cachedInput * cachedPrice
            + Double(completionTokens) * outputPricePerMillion) / 1_000_000
    }

    /// 紧凑展示（<1000 原样，≥1000 显示如 1.2k）。
    static func compact(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }
}
