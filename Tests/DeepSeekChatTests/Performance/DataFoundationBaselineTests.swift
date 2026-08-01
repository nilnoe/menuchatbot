import GRDB
import XCTest

@testable import DeepSeekChat

/// 数据地基性能基线（XCTMeasure）：启动加载 / 侧栏派生计算 / 流式存储吞吐。
///
/// 基线数值由 Xcode 记录；CI 保证能跑通。阈值校准流程见
/// docs/ACCEPTANCE.md §9（先测后定）。
final class DataFoundationBaselineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataBaseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 预置 100 会话 × 100 消息（1 万条）的 SQLite 库（单事务批量插入）。
    private func seed10kMessages() throws {
        // 先让 SessionStore 建好 schema（含 v4 派生列）。
        _ = SessionStore(storageDirectory: tempDir)
        let queue = try DatabaseQueue(
            path: tempDir.appendingPathComponent("sessions.sqlite").path)
        try queue.write { db in
            for sessionIndex in 0..<100 {
                let sessionID = UUID().uuidString
                try db.execute(
                    sql:
                        """
                        INSERT INTO session (id, title, createdAt, updatedAt, isPinned)
                        VALUES (?, ?, ?, ?, 0)
                        """,
                    arguments: [sessionID, "会话\(sessionIndex)", Date(), Date()]
                )
                for messageIndex in 0..<100 {
                    try db.execute(
                        sql:
                            """
                            INSERT INTO message
                            (id, sessionID, role, content, reasoning, sourcesJSON, usageJSON,
                             isSearching, isError, createdAt, position,
                             tokenTotal, contentHash, indexVersion)
                            VALUES (?, ?, 'user', ?, NULL, NULL, NULL, 0, 0, ?, ?, 0, '', 0)
                            """,
                        arguments: [
                            UUID().uuidString, sessionID, "消息\(messageIndex)", Date(),
                            messageIndex,
                        ]
                    )
                }
            }
        }
    }

    /// 启动加载 1 万条消息的库（T1-1b：目标值先测基线再校准）。
    func testStartupLoad10kMessages() throws {
        try seed10kMessages()
        measure {
            _ = SessionStore(storageDirectory: tempDir)
        }
    }

    /// 侧栏派生计算：200 个 summary 排序 + 分组（T1-1d：不再遍历消息正文）。
    func testSidebarDerivedComputation200Sessions() {
        let summaries = (0..<200).map { index in
            SessionSummary(
                id: UUID(),
                title: "标题\(index)",
                createdAt: Date(),
                updatedAt: Date().addingTimeInterval(TimeInterval(index)),
                isPinned: index.isMultiple(of: 5),
                messageCount: 100,
                totalTokens: 1_234,
                lastMessageHasSources: false
            )
        }
        measure {
            let sorted = summaries.sorted { $0.updatedAt > $1.updatedAt }
            let pinned = sorted.filter(\.isPinned)
            let unpinned = sorted.filter { !$0.isPinned }
            _ = Dictionary(grouping: unpinned) { $0.updatedAt }
            _ = pinned.count
        }
    }

    /// 流式存储吞吐：syncMessage 单行 upsert 的写路径（T1-3a 对比基线）。
    func testStreamingStorageThroughput() {
        let store = SessionStore(storageDirectory: tempDir)
        let session = store.createSession()
        let message = ChatMessage(role: .assistant, content: "")
        store.appendMessage(sessionID: session.id, message)
        let state = store.messageState(for: message)
        measure {
            state.appendContent("x")
            state.flushPending()
            store.syncMessage(state, sessionID: session.id)
        }
    }
}
