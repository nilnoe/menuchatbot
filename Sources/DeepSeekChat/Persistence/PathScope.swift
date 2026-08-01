import Foundation

/// 路径包含检查（ADR-0005 D2 / ADR-0006 只读边界）：
/// 规范化 + symlink 解析后确认子路径位于授权根目录内，防 `../` 与 symlink 逃逸。
enum PathScope {
    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = canonicalized(candidate)
        let rootPath = canonicalized(root)
        // 根目录视为"全盘索引"，明确拒绝（用户指定路径而非全盘）。
        guard rootPath != "/" else { return false }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func isContained(_ candidate: URL, in roots: [URL]) -> Bool {
        roots.contains { isContained(candidate, in: $0) }
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
    static func make(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) -> URL? {
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        // 使用期间保持访问授权；调用方负责 start/stop 配对。
        _ = url?.startAccessingSecurityScopedResource()
        return url
    }
}
