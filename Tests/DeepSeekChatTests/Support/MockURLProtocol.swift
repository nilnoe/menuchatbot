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

    private var pendingWork: [DispatchWorkItem] = []
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
        for (index, chunk) in chunks.enumerated() {
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.client?.urlProtocol(self, didLoad: Data(chunk.utf8))
                if index == chunks.count - 1 {
                    self.finished = true
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
            pendingWork.append(item)
            if index == 0 {
                item.perform()
            } else {
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + delay * Double(index), execute: item)
            }
        }
    }

    override func stopLoading() {
        // 取消时立即终止等待，保证流式任务快速收尾（而非等完所有延迟分片）。
        guard !finished else { return }
        pendingWork.forEach { $0.cancel() }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}
