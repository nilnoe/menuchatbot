import Foundation

/// 资料库索引配置（Tier 3-1，ADR-0005 D3）：扫描白名单 / 分块参数。
public struct CorpusIndexOptions: Equatable, Sendable {
    /// 扩展名白名单（小写，无点）；nil = Rust 侧默认。
    public var extensions: [String]?
    /// 单文件大小上限（字节），超出跳过。
    public var maxFileBytes: Int
    /// 分块目标 token（ADR-0005：500~800）。
    public var chunkTokens: Int
    /// 相邻分块重叠 token。
    public var overlapTokens: Int

    public init(
        extensions: [String]? = nil,
        maxFileBytes: Int = 5 * 1024 * 1024,
        chunkTokens: Int = 600,
        overlapTokens: Int = 120
    ) {
        self.extensions = extensions
        self.maxFileBytes = maxFileBytes
        self.chunkTokens = chunkTokens
        self.overlapTokens = overlapTokens
    }
}

/// 单次资料库索引报告（FFI `dc_index_index_corpus` 输出）。
public struct CorpusIndexReport: Equatable, Sendable {
    public var corpusID: String
    public var corpusName: String
    public var filesScanned: Int
    public var filesIndexed: Int
    public var filesSkipped: Int
    public var filesRemoved: Int
    public var chunksAdded: Int
    public var chunksTotal: Int
    public var durationMs: Int

    public init(
        corpusID: String = "",
        corpusName: String = "",
        filesScanned: Int = 0,
        filesIndexed: Int = 0,
        filesSkipped: Int = 0,
        filesRemoved: Int = 0,
        chunksAdded: Int = 0,
        chunksTotal: Int = 0,
        durationMs: Int = 0
    ) {
        self.corpusID = corpusID
        self.corpusName = corpusName
        self.filesScanned = filesScanned
        self.filesIndexed = filesIndexed
        self.filesSkipped = filesSkipped
        self.filesRemoved = filesRemoved
        self.chunksAdded = chunksAdded
        self.chunksTotal = chunksTotal
        self.durationMs = durationMs
    }
}

/// 资料库快照（FFI `dc_index_status` 的 library 字段）。
public struct LibrarySnapshot: Equatable, Sendable {
    public var corpusID: String
    public var documentCount: Int
    public var fileCount: Int
    public var indexedAt: Date?
    public var ready: Bool

    public init(
        corpusID: String = "",
        documentCount: Int = 0,
        fileCount: Int = 0,
        indexedAt: Date? = nil,
        ready: Bool = false
    ) {
        self.corpusID = corpusID
        self.documentCount = documentCount
        self.fileCount = fileCount
        self.indexedAt = indexedAt
        self.ready = ready
    }
}

/// 命名资料库索引契约（Tier 3）：按库索引 / 检索 / 移除 / 取消。
/// UI 与业务层只依赖本协议，不接触 C 类型（DESIGN_RUST_CORE §6.1）。
public protocol LibraryIndexing: Actor {
    /// 增量索引一个资料库目录（扫描 → 分块 → mock embedding → mtime/hash 增量）。
    func indexCorpus(
        corpusID: UUID,
        name: String,
        rootPath: String,
        options: CorpusIndexOptions
    ) async throws -> CorpusIndexReport

    /// 检索某资料库（top-k chunk，命中带来源路径）。
    func search(corpusID: UUID, query: String, limit: Int) async throws -> [SearchHit]

    /// 资料库当前状态（文档数 / 文件数 / 最近索引时间）。
    func snapshot(corpusID: UUID) async -> LibrarySnapshot

    /// 移除资料库索引（关闭句柄并删除落盘目录）。
    func removeCorpus(corpusID: UUID) async throws

    /// 请求取消当前索引任务（操作级标志，不影响搜索）。
    func cancelIndexing() async
}
