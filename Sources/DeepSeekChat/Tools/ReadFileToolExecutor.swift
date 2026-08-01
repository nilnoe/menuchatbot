import Foundation

/// T1 只读文件工具（ADR-0006 D2 / TODO Tier 4，2026-08-01 方向修订）。
///
/// 模型不接触 shell：经结构化 JSON 参数（相对授权根目录的路径 + 起止行号）
/// 调用，执行由 App 进程内完成。读边界：
/// - 只接受**相对**已授权资料库根目录的路径；绝对路径、`..` 逃逸、
///   symlink 逃逸一律拒绝（PathScope 规范化 + 包含检查）；
/// - 扩展名白名单（与 RustCore/src/library.rs `DEFAULT_EXTENSIONS` 同步）；
/// - 文件 > 1MB 明确拒绝；单次最多 200 行；单行 > 4000 字符截断；
///   输出总量 > 12000 字符截断（保护上下文预算，不占用 API 请求）。
struct ReadFileToolExecutor: ToolExecuting {
    /// 授权根目录提供者：App 装配处注入设置页已添加的资料库目录。
    private let rootsProvider: @Sendable () -> [URL]

    init(rootsProvider: @escaping @Sendable () -> [URL]) {
        self.rootsProvider = rootsProvider
    }

    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
        let started = Date()
        do {
            let arguments = try ReadFileArguments(argumentsJSON: request.argumentsJSON)
            if let rangeError = arguments.rangeValidationError {
                return failure(request, started: started, message: rangeError)
            }
            let (root, fileURL) = try resolveFile(arguments.path)
            let output = try readContent(
                at: fileURL,
                relativePath: arguments.path,
                root: root,
                startLine: arguments.startLine ?? 1,
                endLine: arguments.endLine
            )
            return ToolExecutionResult(
                toolName: request.toolName,
                success: true,
                output: output,
                errorMessage: nil,
                duration: Date().timeIntervalSince(started)
            )
        } catch ReadFileArgumentsError.malformedJSON {
            return failure(
                request,
                started: started,
                message: "参数必须是 JSON 对象：{\"path\": \"相对路径\", \"start_line\": 1, \"end_line\": 100}"
            )
        } catch ReadFileArgumentsError.missingPath {
            return failure(request, started: started, message: "缺少 path 参数")
        } catch {
            let message =
                (error as? ReadFileToolError)?.errorDescription
                ?? error.localizedDescription
            return failure(request, started: started, message: message)
        }
    }

    // MARK: - 路径与读取

    /// 解析并校验目标文件：只允许相对授权根目录的路径。
    private func resolveFile(_ path: String) throws -> (root: URL, url: URL) {
        guard !path.isEmpty else {
            throw ReadFileToolError.missingPath
        }
        guard !path.hasPrefix("/") else {
            throw ReadFileToolError.absolutePathDenied
        }
        let roots = rootsProvider()
        for root in roots {
            let candidate = root.appendingPathComponent(path)
            // PathScope 内部做标准化 + symlink 解析，`..` / symlink 逃逸在此拒绝。
            if PathScope.isContained(candidate, in: root) {
                return (root, candidate)
            }
        }
        throw ReadFileToolError.outsideAuthorizedRoots
    }

    /// 按行号范围读取文件；越界 / 超限按文档化策略截断并附说明（T4-2a 可预期）。
    private func readContent(
        at url: URL,
        relativePath: String,
        root: URL,
        startLine: Int,
        endLine: Int?
    ) throws -> String {
        guard ReadFileTool.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ReadFileToolError.extensionNotAllowed(url.pathExtension)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ReadFileToolError.unreadable("文件不存在或无法读取属性")
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw ReadFileToolError.unreadable("无法读取文件大小")
        }
        guard size.int64Value <= Int64(ReadFileTool.maxFileBytes) else {
            throw ReadFileToolError.fileTooLarge(size.int64Value)
        }
        if size.int64Value == 0 {
            return "文件：\(relativePath)（共 0 行）"
        }

        // TCC 授权：已授权目录在未沙箱环境一般无需启动，best-effort 配对调用。
        let accessStarted = root.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                root.stopAccessingSecurityScopedResource()
            }
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ReadFileToolError.unreadable("无法按 UTF-8 读取文件")
        }
        let lines = ReadFileTool.lines(of: content)
        let totalLines = lines.count
        // 先做行号边界校验，再计算结束行：start 必然 ≤ 文件行数（≤1MB 内容），
        // 避免模型传入超大 start_line 时 `start + 上限` 溢出。
        guard startLine <= totalLines else {
            return "文件：\(relativePath)（共 \(totalLines) 行）；起始行 \(startLine) 超出文件范围，无可读内容"
        }
        let requestedEnd =
            endLine
            ?? min(
                startLine + ReadFileTool.maxLinesPerRead - 1,
                totalLines
            )

        var effectiveEnd = min(requestedEnd, totalLines)
        var rangeTruncated = effectiveEnd < requestedEnd
        if effectiveEnd - startLine + 1 > ReadFileTool.maxLinesPerRead {
            effectiveEnd = startLine + ReadFileTool.maxLinesPerRead - 1
            rangeTruncated = true
        }

        var output = "文件：\(relativePath)（第 \(startLine)~\(effectiveEnd) 行 / 共 \(totalLines) 行）"
        if rangeTruncated {
            output += "（已按读取上限截断）"
        }
        output += "\n"
        var appended = false
        for lineNumber in startLine...effectiveEnd {
            let text = ReadFileTool.truncatedLine(lines[lineNumber - 1])
            let piece = (appended ? "\n" : "") + text
            if output.count + piece.count > ReadFileTool.maxOutputChars {
                output += "\n…（输出超限，已截断）"
                break
            }
            output += piece
            appended = true
        }
        return output
    }

    private func failure(
        _ request: ToolExecutionRequest,
        started: Date,
        message: String
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            toolName: request.toolName,
            success: false,
            output: "",
            errorMessage: message,
            duration: Date().timeIntervalSince(started)
        )
    }
}

/// read_file 参数解析错误（区分「JSON 非法」与「缺 path」）。
enum ReadFileArgumentsError: Error, Equatable {
    case malformedJSON
    case missingPath
}

/// read_file 参数解析（MCP 风格结构化参数，拒绝字符串化 shell 命令）。
struct ReadFileArguments: Equatable {
    var path: String
    var startLine: Int?
    var endLine: Int?

    init(argumentsJSON: String) throws {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ReadFileArgumentsError.malformedJSON
        }
        guard let path = json["path"] as? String else {
            throw ReadFileArgumentsError.missingPath
        }
        self.path = path
        self.startLine = json["start_line"] as? Int
        self.endLine = json["end_line"] as? Int
    }

    /// 行号范围合法性；nil 表示合法。
    var rangeValidationError: String? {
        if let startLine, startLine < 1 {
            return "起始行号必须 ≥ 1（实际为 \(startLine)）"
        }
        if let startLine, let endLine, endLine < startLine {
            return "结束行号（\(endLine)）不能小于起始行号（\(startLine)）"
        }
        return nil
    }
}

/// read_file 工具定义与边界常量。
enum ReadFileTool {
    /// 单文件读取上限（1MB）：超出明确拒绝（T4-2a 策略：拒绝而非截断，
    /// 避免"读了一半"误导模型；同时保证主线程有界读取）。
    static let maxFileBytes = 1_000_000
    /// 单次最多行数（含）；请求更大范围时从起始行起截断。
    static let maxLinesPerRead = 200
    /// 单行截断长度（含）；超长行保留前缀并附标记。
    static let maxLineChars = 4_000
    /// 单次输出字符上限：保护上下文预算（约 3k~12k token，取决于语种）。
    static let maxOutputChars = 12_000

    /// 扩展名白名单：与 RustCore/src/library.rs `DEFAULT_EXTENSIONS` 保持同步
    /// （文本类；新增扩展名须两处同改，并由测试断言本集合内容）。
    static let allowedExtensions: Set<String> = [
        "md", "markdown", "txt", "swift", "rs", "py", "json", "yaml", "yml",
        "js", "ts", "tsx", "jsx", "html", "css", "c", "h", "hpp", "cpp", "sh",
        "toml", "sql", "csv", "xml",
    ]

    /// 按 1 起行号切分文本：保留空行；尾随换行不产生额外空行（wc -l 语义）。
    static func lines(of content: String) -> [String] {
        // 先统一换行符：Swift 的 Character 是扩展字形簇，"\r\n" 是一个簇，
        // 直接 split(separator: "\n") 切不开 CRLF，必须先归一化。
        let normalized =
            content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines =
            normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if !normalized.isEmpty,
            normalized.last == "\n",
            lines.last?.isEmpty == true
        {
            lines.removeLast()
        }
        return lines
    }

    /// 超长行截断：保留前缀 + 截断标记。
    static func truncatedLine(_ line: String) -> String {
        guard line.count > maxLineChars else { return line }
        return String(line.prefix(maxLineChars)) + "…（行过长，已截断）"
    }

    static let definition = ToolDefinition(
        name: "read_file",
        description: "读取已授权资料库目录内的文本文件（只读，无 shell）。"
            + "path 为相对某个已授权资料库根目录的路径，如"
            + " \"Sources/DeepSeekChat/Services/DeepSeekClient.swift\"；"
            + "start_line / end_line 为 1 起行号（含），单次最多 200 行。"
            + "只能读取设置中添加的授权目录内文件。",
        parametersJSONSchema: """
            {
              "type": "object",
              "properties": {
                "path": {
                  "type": "string",
                  "description": "相对已授权资料库根目录的文件路径"
                },
                "start_line": {
                  "type": "integer",
                  "description": "起始行号（含），默认 1"
                },
                "end_line": {
                  "type": "integer",
                  "description": "结束行号（含），默认起始行 + 199"
                }
              },
              "required": ["path"]
            }
            """,
        tier: .readFile
    )
}

/// read_file 失败原因（错误信息面向模型与审计，中文可读）。
enum ReadFileToolError: LocalizedError, Equatable {
    case missingPath
    case absolutePathDenied
    case outsideAuthorizedRoots
    case extensionNotAllowed(String)
    case fileTooLarge(Int64)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missingPath:
            return "缺少 path 参数"
        case .absolutePathDenied:
            return "只接受相对授权根目录的路径，拒绝绝对路径"
        case .outsideAuthorizedRoots:
            return "路径不在已授权资料库根目录内，拒绝读取"
        case .extensionNotAllowed(let ext):
            return "扩展名不在白名单内（.\(ext.isEmpty ? "无扩展名" : ext)）"
        case .fileTooLarge(let size):
            return "文件超过 1MB 读取上限（实际 \(size / 1_000_000)MB+）"
        case .unreadable(let reason):
            return "文件不可读：\(reason)"
        }
    }
}
