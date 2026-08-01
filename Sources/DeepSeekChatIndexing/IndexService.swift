import Foundation

/// 可索引文档（SessionStore → IndexService 的输入形态，Tier 3 由
/// IndexCoordinator 从索引事件构造）。
public struct IndexableMessage: Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var position: Int
    public var contentHash: String
    public var content: String
    /// 命名空间：history / library（Tier 3 资料库）。
    public var namespace: String

    public init(
        id: String,
        sessionID: String,
        position: Int,
        contentHash: String,
        content: String,
        namespace: String = "history"
    ) {
        self.id = id
        self.sessionID = sessionID
        self.position = position
        self.contentHash = contentHash
        self.content = content
        self.namespace = namespace
    }
}

/// 检索范围。
public enum SearchScope: Equatable, Sendable {
    case history
    case library(String)

    var namespace: String {
        switch self {
        case .history: return "history"
        case .library: return "library"
        }
    }
}

/// 检索命中。
public struct SearchHit: Equatable, Sendable, Identifiable {
    public var id: String
    public var score: Int
    public var content: String

    public init(id: String, score: Int, content: String) {
        self.id = id
        self.score = score
        self.content = content
    }
}

/// 索引服务状态：ready / unavailable（降级，应用其余功能不受影响，T2-1d）。
public enum IndexState: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// 索引错误（Rust 错误码 → Swift 枚举，DESIGN_RUST_CORE §4.4）。
public enum IndexError: LocalizedError, Equatable {
    case invalidArgument(String)
    case invalidJSON(String)
    case notFound(String)
    case unavailable(String)
    case cancelled
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return "索引参数错误：\(message)"
        case .invalidJSON(let message): return "索引 JSON 错误：\(message)"
        case .notFound(let message): return "索引未找到：\(message)"
        case .unavailable(let message): return "索引不可用：\(message)"
        case .cancelled: return "索引操作已取消"
        case .internalError(let message): return "索引内部错误：\(message)"
        }
    }
}

/// 索引服务契约（ADR-0004 D7 / ADR-0008 D3）：
/// Streaming / Views 只依赖本协议，永不接触 C 类型。
public protocol IndexService: Actor {
    func upsert(_ doc: IndexableMessage) async throws
    func delete(messageID: UUID, sessionID: UUID) async throws
    func search(_ query: String, scope: SearchScope, limit: Int) async throws -> [SearchHit]
    func rebuildIfNeeded() async throws
    var state: IndexState { get }
}
