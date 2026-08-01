import Foundation

/// Streaming 层对会话存储的需求接口（接口隔离）。
///
/// 视图仍直接使用具体的 `SessionStore`；流式编排只依赖本协议，
/// 便于测试注入假存储，也防止控制器隐式耦合存储的全部公开 API。
@MainActor
protocol SessionStoring: MessageSynchronizing {
    /// 会话列表（仅元数据，不含消息正文）。
    var sessions: [SessionSummary] { get }
    /// 会话元数据。
    func summary(id: UUID) -> SessionSummary?
    /// 物化完整会话（按需从数据库加载消息）。
    func session(id: UUID) -> ChatSession?
    /// 惰性加载 / 缓存指定会话的消息。
    func messages(for id: UUID) -> [ChatMessage]
    @discardableResult
    func createSession(title: String) -> SessionSummary
    func renameSession(id: UUID, title: String)
    func appendMessage(sessionID: UUID, _ message: ChatMessage)
    func removeMessage(sessionID: UUID, messageID: UUID)
    /// 就地更新一条已持久化消息（如流式结束后补写 toolCalls）。
    func updateMessage(sessionID: UUID, messageID: UUID, _ mutate: (inout ChatMessage) -> Void)
    func history(for id: UUID) -> [APIMessage]
    func messageState(for message: ChatMessage) -> MessageState
}
