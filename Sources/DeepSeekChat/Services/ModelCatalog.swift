import Foundation

struct ModelInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var supportsResponses: Bool
    /// 是否为用户自定义模型（走 OpenAI 兼容 Chat Completions）。
    var isCustom: Bool = false
    /// USD / 1M tokens：缓存未命中输入单价；nil = 未知（不估算费用）。
    var inputPricePerMillion: Double? = nil
    /// USD / 1M tokens：缓存命中输入单价；nil = 与未命中同价。
    var cachedInputPricePerMillion: Double? = nil
    /// USD / 1M tokens：输出单价；nil = 未知（不估算费用）。
    var outputPricePerMillion: Double? = nil

    /// 消息气泡上展示的短标签。
    var shortName: String {
        if isCustom {
            return name.isEmpty ? id : name
        }
        switch id {
        case "deepseek-v4-pro": return "V4 Pro"
        default: return "V4 Flash"
        }
    }
}

/// 模型目录：内置 DeepSeek 模型 + 用户自定义（OpenAI 兼容）模型。
///
/// 自定义模型只支持标准 Chat Completions（联网搜索 / 思考模式为
/// DeepSeek 专属能力，`supportsResponses` 恒为 false）。
enum ModelCatalog {
    static let builtin: [ModelInfo] = [
        ModelInfo(
            id: "deepseek-v4-flash",
            name: "DeepSeek V4 Flash",
            supportsResponses: true,
            inputPricePerMillion: 0.14,
            cachedInputPricePerMillion: 0.0028,
            outputPricePerMillion: 0.28
        ),
        ModelInfo(
            id: "deepseek-v4-pro",
            name: "DeepSeek V4 Pro（Preview）",
            supportsResponses: false,
            inputPricePerMillion: 0.435,
            cachedInputPricePerMillion: 0.003625,
            outputPricePerMillion: 0.87
        ),
    ]

    /// 合并内置与自定义模型。
    static func all(custom: [CustomModel]) -> [ModelInfo] {
        builtin
            + custom.map {
                ModelInfo(id: $0.id, name: $0.name, supportsResponses: false, isCustom: true)
            }
    }

    /// 按 ID 查找模型；未知 ID 回退到第一个内置模型。
    static func info(_ id: String, custom: [CustomModel]) -> ModelInfo {
        all(custom: custom).first { $0.id == id } ?? builtin[0]
    }
}
