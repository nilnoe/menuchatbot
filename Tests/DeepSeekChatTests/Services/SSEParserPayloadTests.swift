import XCTest

@testable import DeepSeekChat

/// SSE 行解析：`payload(fromLine:)`。
final class SSEParserPayloadTests: XCTestCase {
    func testPayloadFromDataLine() {
        XCTAssertEqual(
            SSEParser.payload(fromLine: "data: {\"a\":1}"),
            "{\"a\":1}"
        )
    }

    func testPayloadTrimsWhitespace() {
        XCTAssertEqual(SSEParser.payload(fromLine: "  data:  hello  "), "hello")
    }

    func testPayloadForDone() {
        XCTAssertEqual(SSEParser.payload(fromLine: "data: [DONE]"), "[DONE]")
    }

    func testPayloadForEmptyData() {
        XCTAssertEqual(SSEParser.payload(fromLine: "data:"), "")
    }

    func testPayloadRejectsNonDataLines() {
        XCTAssertNil(SSEParser.payload(fromLine: "event: message"))
        XCTAssertNil(SSEParser.payload(fromLine: ""))
        XCTAssertNil(SSEParser.payload(fromLine: ": comment"))
    }
}
