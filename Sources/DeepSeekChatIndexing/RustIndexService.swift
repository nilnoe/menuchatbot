import CRustCore
import Foundation

/// Rust 索引配置：namespace / schema 版本（版本不匹配触发自动 rebuild）。
public struct RustIndexConfig: Equatable, Sendable {
    public var namespace: String
    public var schemaVersion: Int

    public init(namespace: String = "history", schemaVersion: Int = 1) {
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

    public init(config: RustIndexConfig = RustIndexConfig()) {
        schemaVersion = config.schemaVersion
        let configJSON = Self.configJSON(config)
        let opened = configJSON.withCString { configPtr in
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
            return SearchHit(id: id, score: score, content: content)
        }
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
