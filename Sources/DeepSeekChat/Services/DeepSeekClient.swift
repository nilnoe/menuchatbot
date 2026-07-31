import Foundation

struct StreamCallbacks {
    var onDelta: (String) -> Void
    var onReasoning: (String) -> Void = { _ in }
    var onSearching: () -> Void = {}
    var onSources: ([Source]) -> Void = { _ in }
    var onDone: () -> Void = {}
    var onError: (String) -> Void = { _ in }
}

enum DeepSeekError: LocalizedError {
    case invalidURL
    case missingAPIKey
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .missingAPIKey:
            return "未配置 API Key：请在设置中填写"
        case .requestFailed(let message):
            return message
        }
    }
}

@MainActor
struct DeepSeekClient {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    init(
        baseURL: String = "https://api.deepseek.com",
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// 校验 API Key：调 GET /models，成功返回可用模型 ID 列表。
    /// 设置页「测试连接」复用此接口，避免为校验单独写造轮子的逻辑。
    func validateAPIKey() async throws -> [String] {
        guard let url = URL(string: baseURL + "/models") else {
            throw DeepSeekError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.requestFailed("无效的服务器响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.requestFailed(SSEParser.parseError(text))
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["data"] as? [[String: Any]]
        else {
            throw DeepSeekError.requestFailed("响应格式异常")
        }
        return models.compactMap { $0["id"] as? String }
    }

    /// Chat Completions 接口（普通对话 / 思考模式）
    func chatCompletions(
        model: String,
        messages: [APIMessage],
        thinking: Bool,
        effort: Effort,
        systemPrompt: String = "",
        temperature: Double? = nil,
        callbacks: StreamCallbacks
    ) async throws {
        var requestMessages = messages
        if !systemPrompt.isEmpty {
            requestMessages.insert(APIMessage(role: "system", content: systemPrompt), at: 0)
        }
        var body: [String: Any] = [
            "model": model,
            "messages": requestMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "thinking": ["type": thinking ? "enabled" : "disabled"],
        ]
        if thinking {
            body["reasoning_effort"] = effort.rawValue
        }
        if let temperature {
            body["temperature"] = temperature
        }
        try await stream(path: "/chat/completions", body: body, kind: .chat, callbacks: callbacks)
    }

    /// Responses API（支持服务端联网搜索）
    func responses(
        model: String,
        input: [APIMessage],
        thinking: Bool,
        effort: Effort,
        webSearch: Bool,
        systemPrompt: String = "",
        temperature: Double? = nil,
        callbacks: StreamCallbacks
    ) async throws {
        var body: [String: Any] = [
            "model": model,
            "input": input.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "reasoning": ["effort": thinking ? effort.rawValue : "none"],
        ]
        if !systemPrompt.isEmpty {
            body["instructions"] = systemPrompt
        }
        if let temperature {
            body["temperature"] = temperature
        }
        if webSearch {
            body["tools"] = [["type": "web_search"]]
        }
        try await stream(path: "/responses", body: body, kind: .responses, callbacks: callbacks)
    }

    // MARK: - 流式 SSE

    private func stream(
        path: String,
        body: [String: Any],
        kind: SSEParser.Kind,
        callbacks: StreamCallbacks
    ) async throws {
        guard let url = URL(string: baseURL + path) else {
            throw DeepSeekError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await chunk in bytes {
                errorData.append(chunk)
            }
            let text = String(data: errorData, encoding: .utf8) ?? ""
            callbacks.onError(SSEParser.parseError(text))
            return
        }

        var finished = false
        for try await rawLine in bytes.lines {
            guard let payload = SSEParser.payload(fromLine: rawLine) else { continue }
            if payload == "[DONE]" {
                callbacks.onDone()
                return
            }
            guard
                let data = payload.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if SSEParser.process(json, kind: kind, callbacks: callbacks) {
                finished = true
                break
            }
        }
        if !finished {
            callbacks.onDone()
        }
    }
}
