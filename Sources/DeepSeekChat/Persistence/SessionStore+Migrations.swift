import Foundation
import GRDB

/// SessionStore 的旧数据迁移（sessions.json / state.json → SQLite）。
///
/// 独立成文件同时满足规模门禁（SessionStore.swift ≤ 800 行）与关注点分离。
extension SessionStore {
    /// 把旧版 sessions.json / state.json 一次性迁入 SQLite（仅当数据库为空时执行）。
    func migrateLegacyDataIfNeeded() {
        do {
            let count = try dbQueue.read { db in try SessionRecord.fetchCount(db) }
            guard count == 0 else { return }

            let jsonURL = directory.appendingPathComponent("sessions.json")
            let legacySessions: [ChatSession]?
            if let data = try? Data(contentsOf: jsonURL),
                let decoded = try? JSONDecoder().decode([ChatSession].self, from: data)
            {
                legacySessions = decoded
            } else if let migrated = Migration.migrateSessions(
                from: directory.appendingPathComponent("state.json"))
            {
                legacySessions = migrated
            } else {
                legacySessions = nil
            }

            guard let legacySessions else { return }
            try dbQueue.write { db in
                for session in legacySessions {
                    try insertSession(session, into: db)
                }
            }
        } catch {
            AppLog.storage.error("迁移旧会话数据失败: \(error, privacy: .public)")
        }
    }
}
