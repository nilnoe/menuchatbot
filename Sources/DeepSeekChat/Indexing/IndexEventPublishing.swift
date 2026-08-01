import Foundation

/// 索引事件：SessionStore → IndexCoordinator（Tier 2 Rust 索引）的事件契约。
///
/// 消息内容变化在 append / update / commit 时发布；流式中间写回
/// （syncMessage，~240ms 一次）**不发布**，避免洪泛——索引以最终内容为准，
/// 必要时由索引重建兜底（索引是派生数据，ADR-0004 D2）。
enum IndexEvent: Equatable {
    case messageUpserted(sessionID: UUID, messageID: UUID, position: Int, contentHash: String)
    case messageDeleted(sessionID: UUID, messageID: UUID)
    case sessionDeleted(UUID)
}

/// 事件源契约：任何持久化实现都可以发布索引事件。
protocol IndexEventPublishing: AnyObject {
    var indexEvents: AsyncStream<IndexEvent> { get }
}
