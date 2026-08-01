import Combine
import DeepSeekChatIndexing
import Foundation

/// 资料库索引状态模型（Tier 3-5）：驱动后台索引任务、进度 / 取消、
/// 单库重新索引；设置页只读展示，业务逻辑集中在 MainActor 上。
@MainActor
final class LibraryIndexModel: ObservableObject {
    /// 单库索引状态（设置页展示）。
    struct CorpusStatus: Equatable, Identifiable {
        let id: UUID
        var isIndexing = false
        var fileCount = 0
        var chunkCount = 0
        var lastIndexedAt: Date?
        var lastError: String?
    }

    @Published private(set) var statuses: [UUID: CorpusStatus] = [:]
    @Published private(set) var isAnyIndexing = false

    private let indexer: LibraryIndexing
    private let corporaProvider: () -> [LibraryCorpus]
    private let audit: AuditLogging
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        indexer: LibraryIndexing,
        corporaProvider: @escaping () -> [LibraryCorpus],
        audit: AuditLogging = NullAuditLogger()
    ) {
        self.indexer = indexer
        self.corporaProvider = corporaProvider
        self.audit = audit
    }

    /// 启动时对全部启用资料库做增量索引（mtime + hash 未变不重 embed），
    /// 并异步刷新既有状态（重启后展示上次索引结果）。
    func start() {
        reindexEnabled()
        Task { await refreshStatuses() }
    }

    /// 单库状态（不存在时返回 nil）。
    func status(for corpusID: UUID) -> CorpusStatus? {
        statuses[corpusID]
    }

    /// 单库重新索引（幂等：进行中再次调用忽略）。
    func reindex(corpus: LibraryCorpus) {
        guard tasks[corpus.id] == nil else { return }
        setStatus(corpus.id) { status in
            status.isIndexing = true
            status.lastError = nil
        }
        audit.record(
            domain: .storage,
            category: AuditCategory.indexRebuildStarted,
            message: "资料库索引开始：\(corpus.name)",
            metadata: ["corpus": corpus.name]
        )
        let task = Task { [weak self] in
            guard let self else { return }
            // TCC 授权：恢复 security-scoped bookmark 并保持访问期间有效。
            var accessedURL: URL?
            if let bookmark = corpus.bookmarkData {
                accessedURL = SecurityScopedBookmark.resolve(
                    bookmark,
                    audit: self.audit
                )
            }
            defer { accessedURL?.stopAccessingSecurityScopedResource() }
            do {
                let report = try await self.indexer.indexCorpus(
                    corpusID: corpus.id,
                    name: corpus.name,
                    rootPath: corpus.path,
                    options: CorpusIndexOptions()
                )
                self.setStatus(corpus.id) { status in
                    status.isIndexing = false
                    status.fileCount = report.filesScanned
                    status.chunkCount = report.chunksTotal
                    status.lastIndexedAt = Date()
                }
                self.audit.record(
                    domain: .storage,
                    category: AuditCategory.indexRebuildFinished,
                    message: "资料库索引完成：\(corpus.name)",
                    metadata: [
                        "corpus": corpus.name,
                        "files": String(report.filesIndexed),
                        "chunks": String(report.chunksTotal),
                    ]
                )
            } catch {
                let message =
                    (error as? IndexError) == .cancelled
                    ? "已取消"
                    : error.localizedDescription
                self.setStatus(corpus.id) { status in
                    status.isIndexing = false
                    status.lastError = message
                }
            }
            self.tasks[corpus.id] = nil
            self.refreshIsIndexing()
        }
        tasks[corpus.id] = task
        refreshIsIndexing()
    }

    func reindexEnabled() {
        for corpus in corporaProvider() where corpus.isEnabled {
            reindex(corpus: corpus)
        }
    }

    /// 停止全部索引任务（Swift 取消 → dc_index_cancel → Rust 轮询退出；
    /// 已索引文件的部分进度已落盘，重启可续跑）。
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        Task { await indexer.cancelIndexing() }
    }

    /// 移除资料库索引（设置页删除库时调用；同时清状态）。
    func remove(corpusID: UUID) async {
        tasks[corpusID]?.cancel()
        tasks[corpusID] = nil
        statuses.removeValue(forKey: corpusID)
        try? await indexer.removeCorpus(corpusID: corpusID)
        refreshIsIndexing()
    }

    /// 从索引器刷新各库状态（启动 / 外部变更后）。
    func refreshStatuses() async {
        for corpus in corporaProvider() {
            let snapshot = await indexer.snapshot(corpusID: corpus.id)
            guard tasks[corpus.id] == nil else { continue }
            setStatus(corpus.id) { status in
                status.fileCount = snapshot.fileCount
                status.chunkCount = snapshot.documentCount
                status.lastIndexedAt = snapshot.indexedAt
            }
        }
        refreshIsIndexing()
    }

    // MARK: - 内部

    private func setStatus(_ id: UUID, _ mutate: (inout CorpusStatus) -> Void) {
        var status = statuses[id] ?? CorpusStatus(id: id)
        mutate(&status)
        statuses[id] = status
    }

    private func refreshIsIndexing() {
        isAnyIndexing = statuses.values.contains { $0.isIndexing }
    }
}
