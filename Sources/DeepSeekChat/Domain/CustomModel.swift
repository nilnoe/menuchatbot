import Foundation

/// 用户自定义的 OpenAI 兼容模型：`id` 是请求体中的 `model` 参数，
/// `name` 是设置页与模型选择器里的展示名。
struct CustomModel: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}
