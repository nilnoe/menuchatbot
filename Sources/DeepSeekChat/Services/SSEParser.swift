import Foundation

/// 纯函数式 SSE 解析器：与网络层解耦，便于单元测试
enum SSEParser {
    enum Kind {
        case chat
        case responses
    }

    /// 从一行 SSE 文本中提取 `data:` 负载；非 data 行返回 nil
    static func payload(fromLine rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }

    /// 处理一个事件 JSON，返回是否为终止事件（response.completed / failed 等）
    @discardableResult
    static func process(_ json: [String: Any], kind: Kind, callbacks: StreamCallbacks) -> Bool {
        switch kind {
        case .chat:
            handleChatEvent(json, callbacks)
            return false
        case .responses:
            return handleResponsesEvent(json, callbacks)
        }
    }

    static func handleChatEvent(_ json: [String: Any], _ callbacks: StreamCallbacks) {
        // include_usage 时，流式收尾块携带整个请求的用量统计（choices 为空）。
        // 需在 delta guard 之前处理，否则空 choices 会提前 return。
        if let usage = json["usage"] as? [String: Any] {
            callbacks.onUsage(
                TokenUsage(
                    promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                    cachedTokens: usage["prompt_cache_hit_tokens"] as? Int ?? 0,
                    completionTokens: usage["completion_tokens"] as? Int ?? 0,
                    totalTokens: usage["total_tokens"] as? Int ?? 0
                )
            )
        }
        guard
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any]
        else { return }
        if let content = delta["content"] as? String, !content.isEmpty {
            callbacks.onDelta(content)
        }
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            callbacks.onReasoning(reasoning)
        }
    }

    @discardableResult
    static func handleResponsesEvent(_ json: [String: Any], _ callbacks: StreamCallbacks) -> Bool {
        guard let type = json["type"] as? String else { return false }

        if type == "response.output_text.delta", let delta = json["delta"] as? String {
            callbacks.onDelta(delta)
        } else if type == "response.reasoning_text.delta", let delta = json["delta"] as? String {
            callbacks.onReasoning(delta)
        } else if type.contains("web_search_call") {
            if type.contains(".in_progress") || type.contains(".searching") {
                callbacks.onSearching()
            }
            if type.contains(".completed") || type.contains(".done") {
                let sources = extractSources(json)
                if !sources.isEmpty {
                    callbacks.onSources(sources)
                }
            }
        } else if type == "response.output_item.done" {
            if let item = json["item"] as? [String: Any],
                item["type"] as? String == "web_search_call"
            {
                let sources = extractSources(json)
                if !sources.isEmpty {
                    callbacks.onSources(sources)
                }
            }
        } else if type == "response.completed" || type == "response.incomplete" {
            // 完成事件携带整个请求的用量统计。
            if let response = json["response"] as? [String: Any],
                let usage = response["usage"] as? [String: Any]
            {
                let details = usage["input_tokens_details"] as? [String: Any] ?? [:]
                callbacks.onUsage(
                    TokenUsage(
                        promptTokens: usage["input_tokens"] as? Int ?? 0,
                        cachedTokens: details["cached_tokens"] as? Int ?? 0,
                        completionTokens: usage["output_tokens"] as? Int ?? 0,
                        totalTokens: usage["total_tokens"] as? Int ?? 0
                    )
                )
            }
            callbacks.onDone()
            return true
        } else if type == "response.failed" {
            let message: String
            if let response = json["response"] as? [String: Any],
                let error = response["error"] as? [String: Any],
                let msg = error["message"] as? String
            {
                message = msg
            } else {
                message = "生成失败（response.failed）"
            }
            callbacks.onError(message)
            return true
        }
        return false
    }

    /// 从任意 JSON 结构中递归提取搜索来源链接（按 URL 去重）
    static func extractSources(_ value: Any) -> [Source] {
        var sources: [Source] = []
        var seen = Set<String>()
        collectSources(value, &sources, &seen)
        return sources
    }

    private static func collectSources(
        _ value: Any,
        _ out: inout [Source],
        _ seen: inout Set<String>
    ) {
        if let array = value as? [Any] {
            for item in array {
                collectSources(item, &out, &seen)
            }
            return
        }
        guard let dict = value as? [String: Any] else { return }
        if let url = dict["url"] as? String, url.hasPrefix("http"), !seen.contains(url) {
            seen.insert(url)
            out.append(Source(title: dict["title"] as? String, url: url))
        }
        for (_, nested) in dict {
            collectSources(nested, &out, &seen)
        }
    }

    /// 从上游错误响应中解析人类可读的错误信息
    static func parseError(_ text: String) -> String {
        if let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        return text.isEmpty ? "请求失败" : String(text.prefix(500))
    }
}
