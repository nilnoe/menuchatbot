import Foundation

/// Streaming 层对会话存储的需求接口（接口隔离）。
///
/// 视图仍直接使用具体的 `SessionStore`；流式编排只依赖本协议，
/// 便于测试注入假存储，也防止控制器隐式耦合存储的全部公开 API。
@MainActor
protocol SessionStoring: MessageSynchronizing {
    func session(id: UUID) -> ChatSession?
    @discardableResult
    func createSession(title: String) -> ChatSession
    func renameSession(id: UUID, title: String)
    func appendMessage(sessionID: UUID, _ message: ChatMessage)
    func removeMessage(sessionID: UUID, messageID: UUID)
    func history(for id: UUID) -> [APIMessage]
    func messageState(for message: ChatMessage) -> MessageState
}
