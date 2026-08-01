import Foundation

/// 路径包含检查（ADR-0005 D2 / ADR-0006 只读边界）：
/// 规范化 + symlink 解析后确认子路径位于授权根目录内，防 `../` 与 symlink 逃逸。
enum PathScope {
    /// 包含检查；传入 audit 时记录通过 / 拒绝事件（ADR-0009 B 域，AU-11）。
    static func isContained(
        _ candidate: URL,
        in root: URL,
        audit: AuditLogging? = nil,
        sessionID: UUID? = nil
    ) -> Bool {
        let candidatePath = canonicalized(candidate)
        let rootPath = canonicalized(root)
        // 根目录视为"全盘索引"，明确拒绝（用户指定路径而非全盘）。
        let contained =
            rootPath != "/"
            && (candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/"))
        recordContainment(
            contained: contained,
            candidate: candidate,
            root: root,
            audit: audit,
            sessionID: sessionID
        )
        return contained
    }

    static func isContained(
        _ candidate: URL,
        in roots: [URL],
        audit: AuditLogging? = nil,
        sessionID: UUID? = nil
    ) -> Bool {
        let contained = roots.contains {
            isContained(candidate, in: $0, audit: nil, sessionID: nil)
        }
        // 多根重载只对外记一次结果（避免每根各记一条）。
        if let audit {
            let rootSummary = roots.map(\.path).joined(separator: "; ")
            audit.record(
                domain: .permission,
                severity: contained ? .info : .warning,
                category: contained ? AuditCategory.pathContained : AuditCategory.pathDenied,
                message: contained ? "路径包含检查通过" : "路径包含检查拒绝",
                sessionID: sessionID,
                metadata: [
                    "candidate": AuditRedactor.summary(for: candidate.path),
                    "roots": AuditRedactor.summary(for: rootSummary),
                ]
            )
        }
        return contained
    }

    private static func recordContainment(
        contained: Bool,
        candidate: URL,
        root: URL,
        audit: AuditLogging?,
        sessionID: UUID?
    ) {
        guard let audit else { return }
        audit.record(
            domain: .permission,
            severity: contained ? .info : .warning,
            category: contained ? AuditCategory.pathContained : AuditCategory.pathDenied,
            message: contained ? "路径包含检查通过" : "路径包含检查拒绝",
            sessionID: sessionID,
            metadata: [
                "candidate": AuditRedactor.summary(for: candidate.path),
                "root": AuditRedactor.summary(for: root.path),
            ]
        )
    }

    /// 规范化路径：先标准化（消除 `..`），再把「最长存在的祖先」解析 symlink，
    /// 最后把剩余组件拼回。`URL.resolvingSymlinksInPath()` 只对已存在的完整
    /// 路径生效，不处理"目标文件尚不存在"的前缀 symlink。
    private static func canonicalized(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        let manager = FileManager.default
        var suffix: [String] = []
        var probe = URL(fileURLWithPath: standardized)
        while !manager.fileExists(atPath: probe.path) {
            let last = probe.lastPathComponent
            guard !last.isEmpty, last != "/" else { return standardized }
            suffix.insert(last, at: 0)
            probe.deleteLastPathComponent()
        }
        let resolved = probe.resolvingSymlinksInPath().path
        let tail = suffix.isEmpty ? "" : "/" + suffix.joined(separator: "/")
        return resolved + tail
    }
}

/// security-scoped bookmark 工具：授权目录的持久化与恢复。
enum SecurityScopedBookmark {
    /// 创建授权 bookmark；传入 audit 时记录授权建立 / 失败（ADR-0009 B 域）。
    static func make(for url: URL, audit: AuditLogging? = nil, sessionID: UUID? = nil) -> Data? {
        let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let audit {
            if data != nil {
                audit.record(
                    domain: .permission,
                    category: AuditCategory.corpusAuthorized,
                    message: "目录授权 bookmark 已创建",
                    sessionID: sessionID,
                    metadata: ["path": AuditRedactor.summary(for: url.path)]
                )
            } else {
                audit.record(
                    domain: .permission,
                    severity: .warning,
                    category: AuditCategory.corpusAuthorized,
                    message: "目录授权 bookmark 创建失败",
                    sessionID: sessionID,
                    metadata: ["path": AuditRedactor.summary(for: url.path)]
                )
            }
        }
        return data
    }

    /// 恢复授权 bookmark；stale 时记录 bookmarkStale（ADR-0009 B 域）。
    static func resolve(_ data: Data, audit: AuditLogging? = nil, sessionID: UUID? = nil) -> URL? {
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        // 使用期间保持访问授权；调用方负责 start/stop 配对。
        _ = url?.startAccessingSecurityScopedResource()
        if let audit {
            if let url {
                audit.record(
                    domain: .permission,
                    severity: isStale ? .warning : .info,
                    category: isStale ? AuditCategory.bookmarkStale : AuditCategory.corpusRestored,
                    message: isStale ? "授权 bookmark 已过期（stale）" : "授权 bookmark 已恢复",
                    sessionID: sessionID,
                    metadata: ["path": AuditRedactor.summary(for: url.path)]
                )
            } else {
                audit.record(
                    domain: .permission,
                    severity: .warning,
                    category: AuditCategory.bookmarkStale,
                    message: "授权 bookmark 恢复失败",
                    sessionID: sessionID
                )
            }
        }
        return url
    }
}
