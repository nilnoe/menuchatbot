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

    /// Chat Completions 接口（普通对话 / 思考模式）
    func chatCompletions(
        model: String,
        messages: [APIMessage],
        thinking: Bool,
        effort: Effort,
        callbacks: StreamCallbacks
    ) async throws {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "thinking": ["type": thinking ? "enabled" : "disabled"]
        ]
        if thinking {
            body["reasoning_effort"] = effort.rawValue
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
        callbacks: StreamCallbacks
    ) async throws {
        var body: [String: Any] = [
            "model": model,
            "input": input.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "reasoning": ["effort": thinking ? effort.rawValue : "none"]
        ]
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
