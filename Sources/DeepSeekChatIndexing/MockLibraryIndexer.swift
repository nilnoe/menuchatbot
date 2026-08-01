import Foundation

/// 内存版资料库索引器：Swift 单测 / 降级路径使用，行为与 Rust 实现对齐
/// （白名单扫描 + token 命中排序），业务测试不依赖 Rust（DESIGN_RUST_CORE §8）。
public actor MockLibraryIndexer: LibraryIndexing {
    private var documents: [UUID: [String: IndexableMessage]] = [:]
    private var paths: [UUID: [String: String]] = [:]
    private var fileCounts: [UUID: Int] = [:]
    private var indexedAts: [UUID: Date] = [:]

    public init() {}

    /// 测试辅助：直接注入文档（不落盘）。
    public func seed(
        corpusID: UUID,
        id: String,
        content: String,
        path: String
    ) {
        documents[corpusID, default: [:]][id] = IndexableMessage(
            id: id,
            sessionID: corpusID.uuidString,
            position: 0,
            contentHash: "hash-\(id)",
            content: content,
            namespace: "library/\(corpusID.uuidString)"
        )
        paths[corpusID, default: [:]][id] = path
        fileCounts[corpusID] = paths[corpusID]?.count ?? 0
    }

    public func indexCorpus(
        corpusID: UUID,
        name: String,
        rootPath: String,
        options: CorpusIndexOptions
    ) async throws -> CorpusIndexReport {
        let allowed =
            options.extensions ?? [
                "md", "txt", "markdown", "swift", "rs", "py", "json", "yaml", "yml",
                "js", "ts", "html", "css", "c", "h", "sh", "toml", "sql",
            ]
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootPath) else {
            throw IndexError.notFound("资料库目录不存在: \(rootPath)")
        }
        var docs: [String: IndexableMessage] = [:]
        var filePaths: [String: String] = [:]
        var files = 0
        guard let enumerator = fm.enumerator(atPath: rootPath) else {
            throw IndexError.notFound("无法枚举资料库目录: \(rootPath)")
        }
        while let relative = enumerator.nextObject() as? String {
            let full = (rootPath as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                allowed.contains((full as NSString).pathExtension.lowercased()),
                let data = fm.contents(atPath: full),
                let text = String(data: data, encoding: .utf8)
            else {
                continue
            }
            let id = "\(corpusID.uuidString)/\(relative)"
            docs[id] = IndexableMessage(
                id: id,
                sessionID: corpusID.uuidString,
                position: 0,
                contentHash: "hash-\(id)",
                content: text,
                namespace: "library/\(corpusID.uuidString)"
            )
            filePaths[id] = full
            files += 1
        }
        documents[corpusID] = docs
        paths[corpusID] = filePaths
        fileCounts[corpusID] = files
        indexedAts[corpusID] = Date()
        return CorpusIndexReport(
            corpusID: corpusID.uuidString,
            corpusName: name,
            filesScanned: files,
            filesIndexed: files,
            chunksTotal: docs.count
        )
    }

    public func search(corpusID: UUID, query: String, limit: Int) async throws -> [SearchHit] {
        let tokens =
            query
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return [] }
        guard let docs = documents[corpusID] else { return [] }
        var hits: [SearchHit] = []
        for doc in docs.values {
            let lowercased = doc.content.lowercased()
            let score = tokens.reduce(0) { $0 + Self.countOccurrences(lowercased, of: $1) }
            if score > 0 {
                hits.append(
                    SearchHit(
                        id: doc.id,
                        score: score,
                        content: doc.content,
                        path: paths[corpusID]?[doc.id] ?? ""
                    )
                )
            }
        }
        hits.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    public func snapshot(corpusID: UUID) async -> LibrarySnapshot {
        LibrarySnapshot(
            corpusID: corpusID.uuidString,
            documentCount: documents[corpusID]?.count ?? 0,
            fileCount: fileCounts[corpusID] ?? 0,
            indexedAt: indexedAts[corpusID],
            ready: true
        )
    }

    public func removeCorpus(corpusID: UUID) async throws {
        documents.removeValue(forKey: corpusID)
        paths.removeValue(forKey: corpusID)
        fileCounts.removeValue(forKey: corpusID)
        indexedAts.removeValue(forKey: corpusID)
    }

    public func cancelIndexing() async {
        // 内存实现无需取消。
    }

    private static func countOccurrences(_ haystack: String, of needle: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
