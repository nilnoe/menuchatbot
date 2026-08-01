import XCTest

@testable import DeepSeekChat

/// 路径包含检查：正常包含、`../` 逃逸、symlink 逃逸、根目录拒绝
/// （ADR-0005 D2 / ADR-0006，ACCEPTANCE T4-1b 的前置契约）。
final class PathScopeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testContainedNestedFile() {
        let root = tempDir.appendingPathComponent("root")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("docs/a.md")
        XCTAssertTrue(PathScope.isContained(file, in: root))
    }

    func testRootItselfIsContained() {
        XCTAssertTrue(PathScope.isContained(tempDir, in: tempDir))
    }

    func testSiblingIsNotContained() {
        let root = tempDir.appendingPathComponent("root")
        let sibling = tempDir.appendingPathComponent("sibling")
        XCTAssertFalse(PathScope.isContained(sibling, in: root))
    }

    func testDotDotEscapeRejected() {
        let root = tempDir.appendingPathComponent("root")
        let escape = root.appendingPathComponent("../secret")
        XCTAssertFalse(PathScope.isContained(escape, in: root))
    }

    func testSymlinkEscapeRejected() throws {
        let root = tempDir.appendingPathComponent("root")
        let outside = tempDir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        let candidate = root.appendingPathComponent("link/secret.txt")
        XCTAssertFalse(PathScope.isContained(candidate, in: root), "symlink 逃逸必须拒绝")
    }

    func testRootDirectoryRejected() {
        XCTAssertFalse(PathScope.isContained(URL(fileURLWithPath: "/etc/passwd"), in: URL(fileURLWithPath: "/")))
    }

    func testContainedInAnyRoot() {
        let rootA = tempDir.appendingPathComponent("a")
        let rootB = tempDir.appendingPathComponent("b")
        let file = rootB.appendingPathComponent("x.txt")
        XCTAssertTrue(PathScope.isContained(file, in: [rootA, rootB]))
        XCTAssertFalse(PathScope.isContained(file, in: [rootA]))
    }

    func testBookmarkRoundTrip() throws {
        let original = tempDir.appendingPathComponent("资料库")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)

        let data = try XCTUnwrap(SecurityScopedBookmark.make(for: original))
        let resolved = try XCTUnwrap(SecurityScopedBookmark.resolve(data))
        // bookmark 解析可能返回真实路径（/private/var 前缀），按 canonicalPath 比较。
        let originalCanonical = try XCTUnwrap(
            original.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let resolvedCanonical = try XCTUnwrap(
            resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        XCTAssertEqual(resolvedCanonical, originalCanonical)
        resolved.stopAccessingSecurityScopedResource()
    }
}
