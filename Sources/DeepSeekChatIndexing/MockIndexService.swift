import Foundation

/// 内存版索引服务：Swift 单测与降级路径使用，与 Rust 实现行为对齐
/// （同词元命中打分排序规则），业务测试不依赖 Rust（DESIGN_RUST_CORE §8）。
public actor MockIndexService: IndexService {
    public private(set) var state: IndexState

    private var documents: [String: IndexableMessage] = [:]

    public init(state: IndexState = .ready) {
        self.state = state
    }

    public var documentCount: Int {
        documents.count
    }

    public func upsert(_ doc: IndexableMessage) async throws {
        try ensureReady()
        documents[doc.id] = doc
    }

    public func delete(messageID: UUID, sessionID: UUID) async throws {
        try ensureReady()
        guard documents.removeValue(forKey: messageID.uuidString) != nil else {
            throw IndexError.notFound("document not found: \(messageID.uuidString)")
        }
    }

    public func search(_ query: String, scope: SearchScope, limit: Int) async throws -> [SearchHit]
    {
        try ensureReady()
        let tokens =
            query
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for doc in documents.values where doc.namespace == scope.namespace {
            let lowercased = doc.content.lowercased()
            let score = tokens.reduce(0) { $0 + Self.countOccurrences(lowercased, of: $1) }
            if score > 0 {
                hits.append(SearchHit(id: doc.id, score: score, content: doc.content))
            }
        }
        hits.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    public func rebuildIfNeeded() async throws {
        try ensureReady()
        // 内存实现无需重建。
    }

    private func ensureReady() throws {
        guard state == .ready else {
            throw IndexError.unavailable("索引不可用")
        }
    }

    private static func countOccurrences(_ haystack: String, of needle: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
