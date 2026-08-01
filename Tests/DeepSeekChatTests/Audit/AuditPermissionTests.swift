import Foundation
import XCTest

@testable import DeepSeekChat

/// AU-11 / AU-12：路径包含检查拒绝矩阵产生审计；注册表白名单自检。
final class AuditPermissionTests: XCTestCase {
    private var tempDir: URL!
    private var recorder: AuditRecorderSink!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditPermission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        recorder = AuditRecorderSink()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testContainedPathRecordsPathContainedAU11() throws {
        let root = tempDir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try Data("内容".utf8).write(to: file)

        XCTAssertTrue(PathScope.isContained(file, in: root, audit: recorder))
        XCTAssertEqual(
            recorder.events(category: AuditCategory.pathContained).count, 1,
            "AU-11：通过检查应记录 pathContained"
        )
    }

    func testParentEscapeRecordsPathDeniedAU11() throws {
        let root = tempDir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let escape = tempDir.appendingPathComponent("root").appendingPathComponent("../secret.txt")

        XCTAssertFalse(PathScope.isContained(escape, in: root, audit: recorder))
        assertDenied()
    }

    func testSymlinkEscapeRecordsPathDeniedAU11() throws {
        let root = tempDir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = tempDir.appendingPathComponent("outside.txt")
        try Data("秘密".utf8).write(to: outside)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertFalse(PathScope.isContained(link, in: root, audit: recorder))
        assertDenied()
    }

    func testRootAsRootRejectedAU11() throws {
        let candidate = tempDir.appendingPathComponent("any")
        XCTAssertFalse(
            PathScope.isContained(candidate, in: URL(fileURLWithPath: "/"), audit: recorder))
        assertDenied()
    }

    func testRegistrySelfCheckPassesForCalculatorAU12() throws {
        let registry = InProcessToolRegistry()
        try registry.register(
            CalculatorTool.definition,
            executor: MockCalculatorExecutor()
        )
        XCTAssertTrue(registry.suspiciousToolNames().isEmpty, "AU-12：calculator 通过自检")
    }

    func testRegistrySelfCheckDetectsWriteLikeToolAU12() throws {
        let registry = InProcessToolRegistry()
        try registry.register(
            ToolDefinition(
                name: "write_file",
                description: "写入文件",
                parametersJSONSchema: #"{"type":"object"}"#,
                tier: .readFile
            ),
            executor: MockCalculatorExecutor()
        )
        XCTAssertTrue(
            registry.suspiciousToolNames().contains("write_file"),
            "AU-12：疑似写 / 删工具必须被自检发现"
        )
    }

    private func assertDenied() {
        XCTAssertEqual(
            recorder.events(category: AuditCategory.pathDenied).count, 1,
            "AU-11：拒绝路径必须记录 pathDenied"
        )
        XCTAssertEqual(
            recorder.events(category: AuditCategory.pathDenied).first?.severity, .warning
        )
    }
}

/// 自检测试用执行器（不执行任何逻辑）。
private final class MockCalculatorExecutor: ToolExecuting {
    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: request.toolName,
            success: true,
            output: "",
            errorMessage: nil,
            duration: 0
        )
    }
}
