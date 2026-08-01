import XCTest

@testable import DeepSeekChat

/// 索引事件发布：增删改、删除会话、导入（Tier 1 第二批，IndexEventPublishing）。
final class SessionStoreIndexEventTests: XCTestCase {
    private var harness: SessionStoreHarness!

    override func setUpWithError() throws {
        harness = try SessionStoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
    }

    private func collectEvents(
        from store: SessionStore, during body: () -> Void
    ) async -> [IndexEvent] {
        // actor 隔离收集：Task 闭包为 @Sendable，捕获的可变数组在新 Swift
        // 并发检查下是错误（CI macos-14 runner 实测）。
        let collector = EventCollector()
        let task = Task {
            for await event in store.indexEvents {
                await collector.append(event)
            }
        }
        // 等消费者挂上（AsyncStream 有缓冲，早发布也不丢）。
        try? await Task.sleep(for: .milliseconds(20))
        body()
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        return await collector.events
    }

    private actor EventCollector {
        private(set) var events: [IndexEvent] = []

        func append(_ event: IndexEvent) {
            events.append(event)
        }
    }

    func testPublishesUpsertDeleteSessionEvents() async {
        let store = harness.makeStore()
        let session = store.createSession(title: "事件")
        let message = ChatMessage(role: .user, content: "hi")

        let events = await collectEvents(from: store) {
            store.appendMessage(sessionID: session.id, message)
            store.removeMessage(sessionID: session.id, messageID: message.id)
            store.deleteSession(id: session.id)
        }

        XCTAssertEqual(
            events,
            [
                .messageUpserted(
                    sessionID: session.id,
                    messageID: message.id,
                    position: 0,
                    contentHash: ContentHash.fnv1a("hi")
                ),
                .messageDeleted(sessionID: session.id, messageID: message.id),
                .sessionDeleted(session.id),
            ]
        )
    }

    func testPublishesUpsertOnUpdateAndCommit() async {
        let store = harness.makeStore()
        let session = store.createSession(title: "更新")
        let message = ChatMessage(role: .assistant, content: "")
        let state = store.messageState(for: message)

        let events = await collectEvents(from: store) {
            store.appendMessage(sessionID: session.id, message)
            store.updateMessage(sessionID: session.id, messageID: message.id) {
                $0.content = "更新后"
            }
            state.appendContent("流式")
            state.flushPending()
            store.commitMessage(state, sessionID: session.id)
        }

        XCTAssertEqual(
            events,
            [
                .messageUpserted(
                    sessionID: session.id,
                    messageID: message.id,
                    position: 0,
                    contentHash: ContentHash.fnv1a("")
                ),
                .messageUpserted(
                    sessionID: session.id,
                    messageID: message.id,
                    position: 0,
                    contentHash: ContentHash.fnv1a("更新后")
                ),
                .messageUpserted(
                    sessionID: session.id,
                    messageID: message.id,
                    position: 0,
                    contentHash: ContentHash.fnv1a("流式")
                ),
            ]
        )
    }

    func testSyncMessageDoesNotPublish() async {
        let store = harness.makeStore()
        let session = store.createSession(title: "中间写回")
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)

        let events = await collectEvents(from: store) {
            state.appendContent("x")
            state.flushPending()
            store.syncMessage(state, sessionID: session.id)
        }

        XCTAssertEqual(
            events,
            [
                .messageUpserted(
                    sessionID: session.id,
                    messageID: message.id,
                    position: 0,
                    contentHash: ContentHash.fnv1a("")
                )
            ],
            "仅 append 发布事件；流式中间写回（syncMessage）不应发布（避免洪泛）"
        )
    }
}
