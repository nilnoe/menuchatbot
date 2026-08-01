import XCTest

@testable import DeepSeekChat

/// 内容指纹：跨调用确定性、敏感性（Tier 1-2，ACCEPTANCE T1-2b）。
final class ContentHashTests: XCTestCase {
    func testSameContentSameHash() {
        XCTAssertEqual(ContentHash.fnv1a("hello"), ContentHash.fnv1a("hello"))
    }

    func testEmptyStringHashIsFNVOffsetBasis() {
        XCTAssertEqual(ContentHash.fnv1a(""), "cbf29ce484222325")
    }

    func testDifferentContentDifferentHash() {
        XCTAssertNotEqual(ContentHash.fnv1a("a"), ContentHash.fnv1a("b"))
    }

    func testReasoningIncludedInHash() {
        XCTAssertNotEqual(
            ContentHash.fnv1a("answer\u{0}think"),
            ContentHash.fnv1a("answer")
        )
    }

    func testHashStableAcrossManyCalls() {
        let hashes = (0..<100).map { _ in ContentHash.fnv1a("稳定内容") }
        XCTAssertEqual(Set(hashes).count, 1)
    }
}
