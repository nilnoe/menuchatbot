import Foundation

/// 流式消息写回契约：把 `MessageState` 的增量提交到持久化层的窄接口。
///
/// 由 `SessionStore` 实现。Streaming 层只依赖本协议描述的写回能力，
/// 避免流式路径隐式耦合存储实现的全部公开 API（接口隔离原则）。
@MainActor
protocol MessageSynchronizing {
    /// 流式期间静默写回（不触发 UI 通知，保证中途退出不丢已生成内容）。
    func syncMessage(_ state: MessageState, sessionID: UUID)

    /// 流式结束 / 停止时写回并发布一次（刷新会话元数据）。
    func commitMessage(_ state: MessageState, sessionID: UUID)
}
