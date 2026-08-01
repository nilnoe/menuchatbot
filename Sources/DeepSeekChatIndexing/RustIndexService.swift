import CRustCore
import Foundation

/// Rust 索引配置：namespace / schema 版本（版本不匹配触发自动 rebuild）。
public struct RustIndexConfig: Equatable, Sendable {
    public var namespace: String
    public var schemaVersion: Int

    public init(namespace: String = "history", schemaVersion: Int = 2) {
        self.namespace = namespace
        self.schemaVersion = schemaVersion
    }
}

/// Rust 索引服务的 Swift 包装：actor 串行化 FFI 入口，UI 主线程永不直接调 FFI。
/// `dc_index_open` 失败时降级为 `.unavailable`，应用其余功能不受影响。
public actor RustIndexService: IndexService {
    public private(set) var state: IndexState

    private let handle: OpaquePointer?
    private let schemaVersion: Int
    /// 索引落盘目录（nil = 纯内存，不持久化）。
    private let indexDirectory: URL?

    /// FFI 句柄的 Sendable 包装：`OpaquePointer` 在 Swift 6 严格并发下不算
    /// Sendable，但底层只是不透明指针，且所有 FFI 调用由 actor 串行化，
    /// 跨线程传递是安全的。
    private struct FFIHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    public init(config: RustIndexConfig = RustIndexConfig(), indexDirectory: URL? = nil) {
        schemaVersion = config.schemaVersion
        self.indexDirectory = indexDirectory
        let configJSON = Self.configJSON(config)
        let opened =
            indexDirectory?.path.withCString { pathPtr in
                configJSON.withCString { configPtr in
                    dc_index_open(pathPtr, configPtr)
                }
            }
            ?? configJSON.withCString { configPtr in
                dc_index_open(nil, configPtr)
            }
        handle = opened
        state =
            opened == nil
            ? .unavailable("Rust 索引打开失败（配置非法或 Rust 核心不可用）")
            : .ready
    }

    deinit {
        if let handle {
            dc_index_close(handle)
        }
    }

    public func upsert(_ doc: IndexableMessage) async throws {
        let handle = try readyHandle()
        let json = Self.messageJSON(doc)
        let code = json.withCString { dc_index_upsert(handle, $0) }
        try Self.throwIfError(code, handle: handle)
    }

    public func delete(messageID: UUID, sessionID: UUID) async throws {
        let handle = try readyHandle()
        let code = messageID.uuidString.withCString { dc_index_delete(handle, $0) }
        try Self.throwIfError(code, handle: handle)
    }

    public func search(_ query: String, scope: SearchScope, limit: Int) async throws -> [SearchHit]
    {
        let handle = try readyHandle()
        let options = Self.optionsJSON(scope: scope, limit: limit)
        var out: UnsafeMutablePointer<CChar>? = nil
        let code = query.withCString { queryPtr in
            options.withCString { optionsPtr in
                dc_index_search(handle, queryPtr, optionsPtr, &out, nil)
            }
        }
        defer { out.map { dc_free($0) } }
        try Self.throwIfError(code, handle: handle)
        guard let out else {
            throw IndexError.internalError("搜索成功但输出为空")
        }
        return Self.parseHits(String(cString: out))
    }

    public func rebuildIfNeeded() async throws {
        let handle = try readyHandle()
        var out: UnsafeMutablePointer<CChar>? = nil
        let code = dc_index_status(handle, &out)
        defer { out.map { dc_free($0) } }
        try Self.throwIfError(code, handle: handle)
        guard let out,
            let data = String(cString: out).data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = json["version"] as? Int
        else {
            throw IndexError.internalError("索引状态解析失败")
        }
        // 内部格式变化 = 重建即迁移（DESIGN_RUST_CORE §9）。
        if version != schemaVersion {
            let rebuildCode = dc_index_rebuild(handle, nil)
            try Self.throwIfError(rebuildCode, handle: handle)
        }
    }

    // MARK: - Tier 3 资料库

    /// 增量索引资料库目录（T3-1：扫描 / 分块 / mtime+hash 增量 / 白名单）。
    public func indexCorpus(
        corpusID: UUID,
        name: String,
        rootPath: String,
        options: CorpusIndexOptions = CorpusIndexOptions()
    ) async throws -> CorpusIndexReport {
        let handle = try readyHandle()
        let optionsJSON = Self.corpusOptionsJSON(
            corpusID: corpusID,
            name: name,
            options: options
        )
        let ffiHandle = FFIHandle(pointer: handle)
        // 长任务放后台线程执行，actor 不阻塞；Swift 任务取消 → dc_index_cancel
        // （Rust 侧按操作轮询取消标志，返回 DC_ERR_CANCELLED，部分进度已落盘）。
        let result: (code: Int32, output: String?) = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                var out: UnsafeMutablePointer<CChar>? = nil
                let code = rootPath.withCString { rootPtr in
                    optionsJSON.withCString { optionsPtr in
                        dc_index_index_corpus(ffiHandle.pointer, rootPtr, optionsPtr, &out, nil)
                    }
                }
                let output = out.map { String(cString: $0) }
                out.map { dc_free($0) }
                return (code, output)
            }.value
        } onCancel: {
            dc_index_cancel(ffiHandle.pointer)
        }
        try Self.throwIfError(result.code, handle: handle)
        guard let output = result.output else {
            throw IndexError.internalError("资料库索引成功但输出为空")
        }
        return Self.parseCorpusReport(output)
    }

    /// 资料库当前快照（文档 / 文件数 / 最近索引时间）。
    public func librarySnapshot(corpusID: UUID) async -> LibrarySnapshot {
        guard let handle, state == .ready else {
            return LibrarySnapshot(corpusID: corpusID.uuidString, ready: false)
        }
        var out: UnsafeMutablePointer<CChar>? = nil
        let code = dc_index_status(handle, &out)
        defer { out.map { dc_free($0) } }
        guard code == DC_OK, let out,
            let data = String(cString: out).data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return LibrarySnapshot(corpusID: corpusID.uuidString, ready: false)
        }
        let indexedAt =
            (json["indexed_at"] as? Int).flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            }
        return LibrarySnapshot(
            corpusID: corpusID.uuidString,
            documentCount: (json["document_count"] as? Int) ?? 0,
            fileCount: (json["files"] as? Int) ?? 0,
            indexedAt: indexedAt,
            ready: (json["ready"] as? Bool) ?? false
        )
    }

    /// 请求取消当前长操作（索引 / 重建）：操作级标志，不影响搜索与写入。
    public func cancelIndexing() {
        guard let handle else { return }
        dc_index_cancel(handle)
    }

    // MARK: - 内部辅助

    private func readyHandle() throws -> OpaquePointer {
        guard state == .ready, let handle else {
            throw IndexError.unavailable("索引不可用")
        }
        return handle
    }

    private static func configJSON(_ config: RustIndexConfig) -> String {
        let escaped = escapeJSON(config.namespace)
        return "{\"namespace\":\"\(escaped)\",\"version\":\(config.schemaVersion)}"
    }

    private static func messageJSON(_ doc: IndexableMessage) -> String {
        let object: [String: Any] = [
            "id": doc.id,
            "content": doc.content,
            "namespace": doc.namespace,
            "session_id": doc.sessionID,
            "position": doc.position,
            "content_hash": doc.contentHash,
        ]
        return encodeJSON(object) ?? "{}"
    }

    private static func optionsJSON(scope: SearchScope, limit: Int) -> String {
        let object: [String: Any] = [
            "limit": max(1, min(limit, 100)),
            "namespace": scope.namespace,
        ]
        return encodeJSON(object) ?? "{}"
    }

    private static func corpusOptionsJSON(
        corpusID: UUID,
        name: String,
        options: CorpusIndexOptions
    ) -> String {
        var object: [String: Any] = [
            "corpus_id": corpusID.uuidString,
            "corpus_name": name,
            "max_file_bytes": options.maxFileBytes,
            "chunk_tokens": options.chunkTokens,
            "overlap_tokens": options.overlapTokens,
        ]
        if let extensions = options.extensions {
            object["extensions"] = extensions
        }
        return encodeJSON(object) ?? "{}"
    }

    private static func encodeJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func escapeJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseHits(_ text: String) -> [SearchHit] {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hits = json["hits"] as? [[String: Any]]
        else {
            return []
        }
        return hits.compactMap { hit in
            guard let id = hit["id"] as? String,
                let score = hit["score"] as? Int,
                let content = hit["content"] as? String
            else {
                return nil
            }
            return SearchHit(
                id: id,
                score: score,
                content: content,
                path: (hit["path"] as? String) ?? ""
            )
        }
    }

    private static func parseCorpusReport(_ text: String) -> CorpusIndexReport {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return CorpusIndexReport()
        }
        return CorpusIndexReport(
            corpusID: (json["corpus_id"] as? String) ?? "",
            corpusName: (json["corpus_name"] as? String) ?? "",
            filesScanned: (json["files_scanned"] as? Int) ?? 0,
            filesIndexed: (json["files_indexed"] as? Int) ?? 0,
            filesSkipped: (json["files_skipped"] as? Int) ?? 0,
            filesRemoved: (json["files_removed"] as? Int) ?? 0,
            chunksAdded: (json["chunks_added"] as? Int) ?? 0,
            chunksTotal: (json["chunks_total"] as? Int) ?? 0,
            durationMs: (json["duration_ms"] as? Int) ?? 0
        )
    }

    private static func throwIfError(_ code: Int32, handle: OpaquePointer) throws {
        guard code != DC_OK else { return }
        throw mapError(code: code, handle: handle)
    }

    private static func mapError(code: Int32, handle: OpaquePointer) -> IndexError {
        let message = lastError(handle)
        switch code {
        case DC_ERR_INVALID_ARGUMENT: return .invalidArgument(message)
        case DC_ERR_JSON: return .invalidJSON(message)
        case DC_ERR_NOT_FOUND: return .notFound(message)
        case DC_ERR_UNAVAILABLE: return .unavailable(message)
        case DC_ERR_CANCELLED: return .cancelled
        default: return .internalError(message)
        }
    }

    private static func lastError(_ handle: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 512)
        let count = dc_index_last_error(handle, &buf, buf.count)
        guard count > 0 else { return "未知错误" }
        return String(cString: buf)
    }
}
