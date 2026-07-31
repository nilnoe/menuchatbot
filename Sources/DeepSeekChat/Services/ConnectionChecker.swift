import Foundation

/// API 连接校验器：把「测试连接」的网络逻辑从视图层抽出，视图不直接持有网络层。
@MainActor
struct ConnectionChecker {
    /// 校验 API Key 并返回可用模型数量。
    func check(
        apiKey: String,
        baseURL: String = AppConfiguration.defaultAPIBaseURL
    ) async -> Result<Int, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(DeepSeekError.missingAPIKey) }
        do {
            let models = try await DeepSeekClient(baseURL: baseURL, apiKey: key).validateAPIKey()
            return .success(models.count)
        } catch {
            return .failure(error)
        }
    }
}
