import Foundation
import GRDB

/// 追加式审计存储（ADR-0009 D3）：独立 audit.sqlite，自有迁移链。
///
/// API 面只有 insert / query / export / prune，**没有 update / delete**（AU-2）；
/// 删除只存在于保留策略的 prune 路径（AU-7）。
final class AuditStore {
    private let dbQueue: DatabaseQueue

    /// 打开独立审计库；目录不存在时自动创建。
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent(Self.databaseFileName)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    /// 内存库：审计库损坏 / 不可用时的降级（AU-4，不阻塞业务）。
    static func inMemory() -> AuditStore {
        let store = try! AuditStore()
        try! store.migrate()
        return store
    }

    private init() throws {
        // 内存库（named: nil）；GRDB 6 两个 init 均声明 throws，内存库不会失败。
        dbQueue = try DatabaseQueue(named: nil)
    }

    private func migrate() throws {
        try Self.migrator.migrate(dbQueue)
    }

    static let databaseFileName = "audit.sqlite"

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "audit_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("eventID", .text).notNull().unique()
                t.column("timestamp", .datetime).notNull()
                t.column("domain", .text).notNull()
                t.column("severity", .text).notNull()
                t.column("category", .text).notNull()
                t.column("message", .text).notNull()
                t.column("sessionID", .text)
                t.column("requestID", .text)
                t.column("metadataJSON", .text)
            }
            try db.create(indexOn: "audit_event", columns: ["timestamp"])
            try db.create(indexOn: "audit_event", columns: ["domain", "severity"])
        }
        return migrator
    }

    // MARK: - 写入（仅追加）

    /// 追加一条事件；失败只落 os_log，不抛给调用方（AU-4）。
    func insert(_ event: AuditEvent) {
        insert([event])
    }

    /// 批量追加（单事务）：保留 / 大流量场景（AU-6 批量入库）。
    func insert(_ events: [AuditEvent]) {
        guard !events.isEmpty else { return }
        do {
            try dbQueue.write { db in
                for event in events {
                    var record = AuditEventRecord(event: event)
                    try record.insert(db)
                }
            }
        } catch {
            AppLog.audit.error("审计事件写入失败: \(error, privacy: .public)")
        }
    }

    // MARK: - 查询 / 导出

    func count() -> Int {
        (try? dbQueue.read { db in try AuditEventRecord.fetchCount(db) }) ?? 0
    }

    /// 最近事件（按 id 倒序）；可按域 / 级别过滤。
    func recent(
        limit: Int = 100,
        domain: AuditDomain? = nil,
        severity: AuditSeverity? = nil
    ) -> [AuditEvent] {
        var request =
            AuditEventRecord
            .order(Column("id").desc)
            .limit(max(1, min(limit, 1000)))
        if let domain {
            request = request.filter(Column("domain") == domain.rawValue)
        }
        if let severity {
            request = request.filter(Column("severity") == severity.rawValue)
        }
        return (try? dbQueue.read { db in try request.fetchAll(db).map(\.event) }) ?? []
    }

    func exportJSON() throws -> Data {
        let events = try dbQueue.read { db in
            try AuditEventRecord.order(Column("id")).fetchAll(db).map(\.event)
        }
        return try JSONEncoder().encode(events)
    }

    // MARK: - 保留策略（AU-7，唯一的删除路径）

    /// 删除指定时间之前的事件，返回删除条数。
    @discardableResult
    func prune(before date: Date) -> Int {
        do {
            return try dbQueue.write { db in
                try AuditEventRecord.filter(Column("timestamp") < date).deleteAll(db)
            }
        } catch {
            AppLog.audit.error("审计保留修剪失败: \(error, privacy: .public)")
            return 0
        }
    }

    /// 按估算字节数滚动：超出 maxBytes 时从最旧开始删除，返回删除条数。
    @discardableResult
    func pruneToApproximateSize(_ maxBytes: Int) -> Int {
        do {
            return try dbQueue.write { db in
                let rows: [(id: Int64, bytes: Int)] = try Row.fetchAll(
                    db,
                    sql:
                        """
                        SELECT id,
                               length(message) + COALESCE(length(metadataJSON), 0) + 128 AS bytes
                        FROM audit_event
                        ORDER BY id DESC
                        """
                ).map { row in
                    (id: row["id"], bytes: row["bytes"])
                }
                var keep = rows
                var total = rows.reduce(0) { $0 + $1.bytes }
                var removed: [Int64] = []
                while total > maxBytes, let oldest = keep.popLast() {
                    removed.append(oldest.id)
                    total -= oldest.bytes
                }
                for id in removed {
                    try db.execute(
                        sql: "DELETE FROM audit_event WHERE id = ?",
                        arguments: [id]
                    )
                }
                return removed.count
            }
        } catch {
            AppLog.audit.error("审计容量修剪失败: \(error, privacy: .public)")
            return 0
        }
    }

    /// 执行完整保留策略（天数 + 容量），返回删除总数。
    @discardableResult
    func runRetention(days: Int, maxBytes: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        return prune(before: cutoff) + pruneToApproximateSize(maxBytes)
    }
}

// MARK: - GRDB Record

/// audit_event 表记录（仅追加）。
private struct AuditEventRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "audit_event"

    var id: Int64?
    var eventID: String
    var timestamp: Date
    var domain: String
    var severity: String
    var category: String
    var message: String
    var sessionID: String?
    var requestID: String?
    var metadataJSON: String?

    init(event: AuditEvent) {
        id = event.id
        eventID = event.eventID.uuidString
        timestamp = event.timestamp
        domain = event.domain.rawValue
        severity = event.severity.rawValue
        category = event.category
        message = event.message
        sessionID = event.sessionID?.uuidString
        requestID = event.requestID
        metadataJSON = event.metadataJSON
    }

    var event: AuditEvent {
        AuditEvent(
            id: id,
            eventID: UUID(uuidString: eventID) ?? UUID(),
            timestamp: timestamp,
            domain: AuditDomain(rawValue: domain) ?? .config,
            severity: AuditSeverity(rawValue: severity) ?? .info,
            category: category,
            message: message,
            sessionID: sessionID.flatMap(UUID.init(uuidString:)),
            requestID: requestID,
            metadataJSON: metadataJSON
        )
    }
}
