import Foundation

/// 多资料库索引编排（Tier 3）：每库一个 `RustIndexService` 句柄，
/// 落盘目录 `<indexRoot>/<corpusID>/`，支持独立索引 / 检索 / 移除 / 取消。
///
/// 索引是派生数据（ADR-0004）：目录可整体删除，SQLite 仍是事实源。
public actor RustLibraryIndexer: LibraryIndexing {
    private let indexRoot: URL
    private var services: [UUID: RustIndexService] = [:]

    public init(indexRoot: URL) {
        self.indexRoot = indexRoot
    }

    public func indexCorpus(
        corpusID: UUID,
        name: String,
        rootPath: String,
        options: CorpusIndexOptions
    ) async throws -> CorpusIndexReport {
        let service = try await service(for: corpusID)
        return try await service.indexCorpus(
            corpusID: corpusID,
            name: name,
            rootPath: rootPath,
            options: options
        )
    }

    public func search(corpusID: UUID, query: String, limit: Int) async throws -> [SearchHit] {
        let service = try await service(for: corpusID)
        return try await service.search(
            query,
            scope: .library(corpusID.uuidString),
            limit: limit
        )
    }

    public func snapshot(corpusID: UUID) async -> LibrarySnapshot {
        guard let service = services[corpusID] else {
            return LibrarySnapshot(corpusID: corpusID.uuidString, ready: false)
        }
        return await service.librarySnapshot(corpusID: corpusID)
    }

    public func removeCorpus(corpusID: UUID) async throws {
        // 移除引用 → deinit 关闭句柄并保存；随后删除落盘目录。
        services.removeValue(forKey: corpusID)
        let directory = indexRoot.appendingPathComponent(corpusID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func cancelIndexing() async {
        for service in services.values {
            await service.cancelIndexing()
        }
    }

    // MARK: - 内部

    private func service(for corpusID: UUID) async throws -> RustIndexService {
        if let existing = services[corpusID] {
            return existing
        }
        let directory = indexRoot.appendingPathComponent(corpusID.uuidString, isDirectory: true)
        let service = RustIndexService(
            config: RustIndexConfig(
                namespace: "library/\(corpusID.uuidString)",
                schemaVersion: 2
            ),
            indexDirectory: directory
        )
        guard await service.state == .ready else {
            throw IndexError.unavailable("资料库索引不可用（Rust 核心未就绪）")
        }
        services[corpusID] = service
        return service
    }
}
