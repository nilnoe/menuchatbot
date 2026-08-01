import Combine
import GRDB
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

    // MARK: - 流式存储写放大（Tier 1-3，ACCEPTANCE T1-3a / T1-3c）

    func testSyncWritesRowWithoutTouchingSessionUntilCommit() throws {
        let store = harness.makeStore()
        let session = store.createSession(title: "写放大")
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)

        let queue = try DatabaseQueue(
            path: harness.tempDir.appendingPathComponent("sessions.sqlite").path)
        let sessionUpdatedAt = { () throws -> Date in
            try queue.read { db in
                try Date.fetchOne(db, sql: "SELECT updatedAt FROM session") ?? .distantPast
            }
        }
        let before = try sessionUpdatedAt()
        Thread.sleep(forTimeInterval: 0.01)

        state.appendContent("流式内容")
        state.flushPending()
        store.syncMessage(state, sessionID: session.id)

        // 中间写回：消息行已落库（崩溃恢复不丢内容），会话时间戳不动。
        let content = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM message")
        }
        XCTAssertEqual(content, "流式内容")
        XCTAssertEqual(try sessionUpdatedAt(), before, "中间 sync 不应 touch 会话时间戳")

        store.commitMessage(state, sessionID: session.id)
        let afterCommit = try sessionUpdatedAt()
        XCTAssertGreaterThan(
            afterCommit.timeIntervalSince(before), 0, "commit 应把会话时间戳落库")
    }

    // MARK: - messageStates LRU（Tier 1-4，ACCEPTANCE T1-4a / T1-4b）

    func testMessageStatesEvictedAtLimit() {
        let store = harness.makeStore()
        let messages = (0..<250).map { ChatMessage(role: .user, content: "m\($0)") }
        var states: [UUID: MessageState] = [:]
        for message in messages {
            states[message.id] = store.messageState(for: message)
        }

        XCTAssertLessThanOrEqual(store.messageStateCount, 200, "状态数不应超过上限")
        // 最早创建的已被逐出：再取得到新实例。
        XCTAssertFalse(states[messages[0].id] === store.messageState(for: messages[0]))
        // 最近创建的仍共享同一实例。
        XCTAssertTrue(states[messages[249].id] === store.messageState(for: messages[249]))
    }

    func testRecentlyTouchedStateSurvivesEviction() {
        let store = harness.makeStore()
        let messages = (0..<200).map { ChatMessage(role: .user, content: "m\($0)") }
        var states: [UUID: MessageState] = [:]
        for message in messages {
            states[message.id] = store.messageState(for: message)
        }

        // 重新触摸第一条（移到最热端），再插入两条触发逐出。
        XCTAssertTrue(states[messages[0].id] === store.messageState(for: messages[0]))
        let extra1 = ChatMessage(role: .user, content: "x1")
        let extra2 = ChatMessage(role: .user, content: "x2")
        _ = store.messageState(for: extra1)
        _ = store.messageState(for: extra2)

        XCTAssertTrue(
            states[messages[0].id] === store.messageState(for: messages[0]),
            "最近触摸的消息状态不应被逐出")
        XCTAssertFalse(
            states[messages[1].id] === store.messageState(for: messages[1]),
            "最久未用的消息状态应被逐出")
        XCTAssertTrue(store.messageState(for: extra2) === store.messageState(for: extra2))
    }
}
