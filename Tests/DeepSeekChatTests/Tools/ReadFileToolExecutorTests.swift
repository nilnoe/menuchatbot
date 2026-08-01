import XCTest

@testable import DeepSeekChat

/// T1 只读文件工具执行器（Tier 4 / ACCEPTANCE §7 T4-1、T4-2、T4-4 前置）：
/// 结构化参数、路径包含检查、扩展名白名单、大小 / 行数 / 单行 / 输出上限。
final class ReadFileToolExecutorTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    // MARK: - 正常读取

    func testReadsRequestedLineRange() async throws {
        let root = try makeRoot()
        try write("l1\nl2\nl3\nl4\nl5\n", to: "sample.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"sample.txt","start_line":2,"end_line":4}"#))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("第 2~4 行 / 共 5 行"))
        XCTAssertTrue(result.output.contains("l2"))
        XCTAssertTrue(result.output.contains("l4"))
        XCTAssertFalse(result.output.contains("l1"))
        XCTAssertFalse(result.output.contains("l5"))
    }

    func testDefaultsToWholeSmallFile() async throws {
        let root = try makeRoot()
        try write("a\nb\nc\n", to: "doc.md", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"doc.md"}"#))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("第 1~3 行 / 共 3 行"))
        XCTAssertTrue(result.output.contains("a\nb\nc"))
    }

    func testReadsNestedPath() async throws {
        let root = try makeRoot()
        try write("body\n", to: "Sources/App/File.swift", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"Sources/App/File.swift"}"#)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("body"))
    }

    func testCRLFAndEmptyLinesKeepNumbering() async throws {
        let root = try makeRoot()
        try write("a\r\n\r\nb\r\nc\n", to: "win.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"win.txt","start_line":1,"end_line":4}"#)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("共 4 行"))
        XCTAssertTrue(result.output.contains("a\n\nb\nc"))
    }

    func testEmptyFileReturnsZeroLines() async throws {
        let root = try makeRoot()
        try write("", to: "empty.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"empty.txt"}"#))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("共 0 行"))
    }

    // MARK: - 路径边界（T4-1b 越权读取全部拒绝）

    func testRejectsAbsolutePath() async throws {
        let root = try makeRoot()
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"/etc/hosts"}"#))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("绝对路径") == true)
    }

    func testRejectsTraversalOutsideRoot() async throws {
        let root = try makeRoot()
        let name = "secret-\(UUID().uuidString).txt"
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent(name)
        try write("secret\n", to: outside)
        tempRoots.append(outside)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request("{\"path\":\"../\(name)\"}")
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("不在已授权") == true)
    }

    func testRejectsSymlinkEscape() async throws {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try write("outside\n", to: outside)
        tempRoots.append(outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: outside
        )
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"link.txt"}"#))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("不在已授权") == true)
    }

    func testRejectsPathOutsideAllRoots() async throws {
        let root = try makeRoot()
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"does-not-exist.swift"}"#)
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("文件不可读") == true)
    }

    // MARK: - 内容边界（T4-2a）

    func testRejectsExtensionOutsideWhitelist() async throws {
        let root = try makeRoot()
        try write("x\n", to: "notes.pdf", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"notes.pdf"}"#))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("扩展名不在白名单") == true)
    }

    func testRejectsOversizedFile() async throws {
        let root = try makeRoot()
        let data = Data(repeating: 0x61, count: ReadFileTool.maxFileBytes + 1)
        try data.write(to: root.appendingPathComponent("big.txt"))
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"big.txt"}"#))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("超过 1MB") == true)
    }

    func testClampsEndLineToEndOfFile() async throws {
        let root = try makeRoot()
        try write(
            (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n", to: "t.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"t.txt","start_line":5,"end_line":999}"#)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("第 5~10 行 / 共 10 行"))
        XCTAssertTrue(result.output.contains("已按读取上限截断"))
        XCTAssertTrue(result.output.contains("line10"))
        XCTAssertFalse(result.output.contains("line4"))
    }

    func testCapsRequestedRangeLength() async throws {
        let root = try makeRoot()
        try write(
            (1...300).map { "line\($0)" }.joined(separator: "\n") + "\n", to: "big.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"big.txt","start_line":1,"end_line":300}"#)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("第 1~200 行 / 共 300 行"))
        XCTAssertTrue(result.output.contains("line200"))
        XCTAssertFalse(result.output.contains("line201"))
    }

    func testStartLineBeyondEndOfFileReturnsNote() async throws {
        let root = try makeRoot()
        try write("a\nb\n", to: "short.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"short.txt","start_line":5}"#)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("起始行 5 超出文件范围"))
    }

    func testHugeStartLineDoesNotOverflow() async throws {
        let root = try makeRoot()
        try write("a\nb\n", to: "short.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"short.txt","start_line":9223372036854775807}"#)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("超出文件范围"))
    }

    func testLongLineIsTruncated() async throws {
        let root = try makeRoot()
        try write(String(repeating: "x", count: 5_000) + "\n", to: "long.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"long.txt"}"#))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("行过长，已截断"))
        let payload = result.output.replacingOccurrences(of: "…（行过长，已截断）", with: "")
        XCTAssertLessThan(payload.count, ReadFileTool.maxOutputChars)
    }

    func testOutputIsCapped() async throws {
        let root = try makeRoot()
        let lines = (1...300).map { String(repeating: "y", count: 200) + "\($0)" }
        try write(lines.joined(separator: "\n") + "\n", to: "huge.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"path":"huge.txt"}"#))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("输出超限，已截断"))
        XCTAssertLessThan(result.output.count, ReadFileTool.maxOutputChars + 64)
    }

    // MARK: - 参数校验

    func testRejectsMalformedArguments() async throws {
        let root = try makeRoot()
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request("not json"))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("参数必须是 JSON") == true)
    }

    func testRejectsMissingPath() async throws {
        let root = try makeRoot()
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(request(#"{"start_line":1}"#))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("缺少 path") == true)
    }

    func testRejectsStartLineBelowOne() async throws {
        let root = try makeRoot()
        try write("a\n", to: "t.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"t.txt","start_line":0}"#)
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("起始行号必须 ≥ 1") == true)
    }

    func testRejectsEndLineBelowStartLine() async throws {
        let root = try makeRoot()
        try write("a\nb\n", to: "t.txt", in: root)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            request(#"{"path":"t.txt","start_line":5,"end_line":3}"#)
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorMessage?.contains("结束行号") == true)
    }

    // MARK: - 定义与白名单

    func testDefinitionMatchesMCPShape() {
        XCTAssertEqual(ReadFileTool.definition.name, "read_file")
        XCTAssertEqual(ReadFileTool.definition.tier, .readFile)
        let schema =
            try? JSONSerialization.jsonObject(
                with: Data(ReadFileTool.definition.parametersJSONSchema.utf8)
            ) as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual((schema?["required"] as? [String])?.first, "path")
        let properties = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["path"])
        XCTAssertNotNil(properties?["start_line"])
        XCTAssertNotNil(properties?["end_line"])
    }

    /// 白名单与 RustCore/src/library.rs `DEFAULT_EXTENSIONS` 保持同步
    /// （Rust 列表变更时此处必须同改，本测试防静默漂移）。
    func testWhitelistMatchesRustDefaultExtensions() {
        let rustDefault: Set<String> = [
            "md", "markdown", "txt", "swift", "rs", "py", "json", "yaml", "yml",
            "js", "ts", "tsx", "jsx", "html", "css", "c", "h", "hpp", "cpp", "sh",
            "toml", "sql", "csv", "xml",
        ]
        XCTAssertEqual(ReadFileTool.allowedExtensions, rustDefault)
    }

    // MARK: - 工具辅助

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadFileToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func write(_ content: String, to relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeExecutor(root: URL) -> ReadFileToolExecutor {
        ReadFileToolExecutor(rootsProvider: { [root] in [root] })
    }

    private func request(_ arguments: String) -> ToolExecutionRequest {
        ToolExecutionRequest(toolName: "read_file", argumentsJSON: arguments, sessionID: nil)
    }
}
