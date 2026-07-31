import Foundation
import XCTest

@testable import DeepSeekChat

/// 记录流式回调调用
final class CallbackRecorder {
    var deltas: [String] = []
    var reasoning: [String] = []
    var searchingCount = 0
    var sources: [[Source]] = []
    var usages: [TokenUsage] = []
    var doneCount = 0
    var errors: [String] = []

    var callbacks: StreamCallbacks {
        StreamCallbacks(
            onDelta: { [self] in deltas.append($0) },
            onReasoning: { [self] in reasoning.append($0) },
            onSearching: { [self] in searchingCount += 1 },
            onSources: { [self] in sources.append($0) },
            onUsage: { [self] in usages.append($0) },
            onDone: { [self] in doneCount += 1 },
            onError: { [self] in errors.append($0) }
        )
    }
}

/// 内存版 Keychain
final class MockKeychain: KeychainStoring {
    var storage: [String: String] = [:]
    var writeCount = 0
    var deleteCount = 0

    func read(account: String) -> String? {
        storage[account]
    }

    func write(account: String, value: String) {
        storage[account] = value
        writeCount += 1
    }

    func delete(account: String) {
        storage.removeValue(forKey: account)
        deleteCount += 1
    }
}

/// 拦截 URLSession 请求，返回预设的响应
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

extension XCTestCase {
    func makeDelayedStreamingURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedStreamingURLProtocol.self]
        return URLSession(configuration: config)
    }

    func makeMockURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func httpResponse(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    /// URLSession 可能把 httpBody 转成 httpBodyStream，这里两种都支持
    func httpBody(of request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotParseResponse)
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
