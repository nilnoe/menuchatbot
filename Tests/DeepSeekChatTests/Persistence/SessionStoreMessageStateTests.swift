import Combine
import XCTest

@testable import DeepSeekChat

/// 消息状态（流式性能契约）：增量缓冲、聚合发布、错误丢弃、生命周期标记。
final class SessionStoreMessageStateTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    func testMessageStateIsSharedPerMessage() {
        let store = harness.makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "初始")
        store.appendMessage(sessionID: session.id, message)

        let first = store.messageState(for: message)
        let second = store.messageState(for: message)
        XCTAssertTrue(first === second, "同一消息应复用同一个状态对象")
        XCTAssertEqual(first.content, "初始")
        XCTAssertEqual(first.role, .assistant)
    }

    func testSyncMessageWritesThroughWithoutPublishing() {
        let store = harness.makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)

        var publishCount = 0
        let cancellable = store.objectWillChange.sink { publishCount += 1 }
        _ = cancellable

        state.appendContent("流式内容")
        state.appendReasoning("推理片段")
        state.setSearching(true)
        state.flushPending()
        store.syncMessage(state, sessionID: session.id)

        XCTAssertEqual(publishCount, 0, "流式写回不应触发整树刷新")
        let stored = store.session(id: session.id)?.messages[0]
        XCTAssertEqual(stored?.content, "流式内容")
        XCTAssertEqual(stored?.reasoning, "推理片段")
        XCTAssertTrue(stored?.isSearching ?? false)
    }

    func testCommitMessagePublishesOnceAndFlushes() {
        let store = harness.makeStore()
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)

        var publishCount = 0
        let cancellable = store.objectWillChange.sink { publishCount += 1 }
        _ = cancellable

        state.appendContent("最终内容")
        state.flushPending()
        store.commitMessage(state, sessionID: session.id)

        XCTAssertEqual(publishCount, 1, "流式结束只应发布一次")
        let stored = store.session(id: session.id)?.messages[0]
        XCTAssertEqual(stored?.content, "最终内容")
        XCTAssertFalse(stored?.isError ?? true)
    }

    func testMessageStateCoalescesDeltasUntilFlush() {
        let message = ChatMessage(role: .assistant, content: "")
        let state = MessageState(message: message)
        var publishCount = 0
        let cancellable = state.objectWillChange.sink { publishCount += 1 }
        _ = cancellable

        state.appendContent("你")
        state.appendContent("好")
        state.appendReasoning("深")
        state.appendReasoning("思")

        XCTAssertEqual(state.content, "", "聚合前不应发布到 UI")
        // 第一个分片触发一次 isStreaming 标记（一次性，后续分片不再发布）。
        XCTAssertEqual(publishCount, 1, "分片只进缓冲，仅流式标记发布一次")

        state.flushPending()
        XCTAssertEqual(state.content, "你好")
        XCTAssertEqual(state.reasoning, "深思")
        // content 与 reasoning 两个 @Published 字段各触发一次；
        // 同一 runloop 内 SwiftUI 会合并为一次视图更新。
        XCTAssertEqual(publishCount, 3, "发布 = 流式标记 1 次 + flush 字段 2 次")
        XCTAssertFalse(state.hasPendingChanges)
    }

    func testMessageStateErrorDiscardsPendingDeltas() {
        let message = ChatMessage(role: .assistant, content: "")
        let state = MessageState(message: message)
        state.appendContent("部分内容")
        state.setError("出错了")

        XCTAssertEqual(state.content, "出错了")
        XCTAssertTrue(state.isError)

        state.flushPending()
        XCTAssertEqual(state.content, "出错了", "flush 不应把已丢弃的增量加回")
    }

    func testMessageStateTracksStreamingLifecycle() {
        let message = ChatMessage(role: .assistant, content: "")
        let state = MessageState(message: message)
        XCTAssertFalse(state.isStreaming)

        state.appendContent("a")
        XCTAssertTrue(state.isStreaming, "收到分片后应标记为流式")
        state.appendReasoning("r")
        XCTAssertTrue(state.isStreaming)

        state.flushPending()
        XCTAssertTrue(state.isStreaming, "聚合 flush 不结束流式")

        state.markStreamEnded()
        XCTAssertFalse(state.isStreaming, "结束标记后恢复非流式渲染")
    }
}
