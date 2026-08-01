import Foundation
import XCTest

extension XCTestCase {
    /// 注入 `DelayedStreamingURLProtocol` 的会话（分片按时间间隔投递）。
    func makeDelayedStreamingURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedStreamingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 注入 `MockURLProtocol` 的会话（响应完全由 handler 决定）。
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

    /// URLSession 可能把 httpBody 转成 httpBodyStream，这里两种都支持。
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
