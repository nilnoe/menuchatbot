import Foundation
import XCTest

@testable import DeepSeekChat

/// 记录流式回调调用
final class CallbackRecorder {
    var deltas: [String] = []
    var reasoning: [String] = []
    var searchingCount = 0
    var sources: [[Source]] = []
    var doneCount = 0
    var errors: [String] = []

    var callbacks: StreamCallbacks {
        StreamCallbacks(
            onDelta: { [self] in deltas.append($0) },
            onReasoning: { [self] in reasoning.append($0) },
            onSearching: { [self] in searchingCount += 1 },
            onSources: { [self] in sources.append($0) },
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

extension XCTestCase {
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
