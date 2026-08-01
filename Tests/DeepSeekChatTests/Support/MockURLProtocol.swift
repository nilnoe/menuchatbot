import Foundation

/// 拦截 URLSession 请求，返回预设的响应。
///
/// 使用方式：给 `handler` 赋闭包，闭包内用 `httpResponse(_:status:)` 构造响应；
/// 再通过 `makeMockURLSession()` 创建注入客户端的会话。
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 可控时序的流式 URLProtocol：分片按固定间隔逐条投递，
/// 用于确定性测试流式生命周期与竞态（取消后旧任务延迟收尾等场景）。
final class DelayedStreamingURLProtocol: URLProtocol {
    /// 返回 (响应, 分片列表, 分片间隔秒)。第一片立即投递，后续按间隔延迟。
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, [String], TimeInterval))?

    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let (response, chunks, delay) = try? Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliverChunks(chunks, delay: delay, at: 0)
    }

    override func stopLoading() {
        // 取消时立即终止等待，保证流式任务快速收尾（而非等完所有延迟分片）。
        guard !finished else { return }
        // 置位后，链式投递中已调度但尚未执行的下一片会直接放弃。
        finished = true
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    /// 链式投递：每片投递完才调度下一片（固定间隔），保证分片严格有序。
    /// 若为每个分片各自 asyncAfter 到全局并发队列，慢机负载下多片可能并行，
    /// [DONE] 先于 usage 等末尾事件到达会让客户端提前 return，丢掉后续事件。
    private func deliverChunks(_ chunks: [String], delay: TimeInterval, at index: Int) {
        guard !finished else { return }
        guard index < chunks.count else {
            finished = true
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.client?.urlProtocol(self, didLoad: Data(chunks[index].utf8))
            self.deliverChunks(chunks, delay: delay, at: index + 1)
        }
        if index == 0 {
            item.perform()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
}
