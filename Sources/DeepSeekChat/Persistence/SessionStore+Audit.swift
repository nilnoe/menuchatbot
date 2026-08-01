import Foundation

/// SessionStore 的审计挂点（ADR-0009 D 域）：迁移 / 降级 / 导入导出 / 删除。
///
/// 独立成文件同时满足规模门禁（SessionStore.swift ≤ 800 行）与审计关注点分离。
extension SessionStore {
    func auditDbFallbackToMemory(reason: String) {
        audit.record(
            domain: .storage,
            severity: .critical,
            category: AuditCategory.dbFallbackToMemory,
            message: "会话数据库打开失败，改用内存库（数据不落盘）",
            metadata: ["reason": reason]
        )
    }

    func auditMigrationApplied(migrations: [String]) {
        audit.record(
            domain: .storage,
            category: AuditCategory.migrationApplied,
            message: "数据库迁移完成",
            metadata: ["migrations": migrations.joined(separator: ",")]
        )
    }

    func auditMigrationFailed(reason: String) {
        audit.record(
            domain: .storage,
            severity: .critical,
            category: AuditCategory.migrationFailed,
            message: "数据库迁移失败",
            metadata: ["reason": reason]
        )
    }

    func auditSessionDeleted(id: UUID) {
        audit.record(
            domain: .storage,
            category: AuditCategory.sessionDeleted,
            message: "会话已删除",
            sessionID: id
        )
    }

    func auditExportFinished(sessionCount: Int, bytes: Int) {
        audit.record(
            domain: .storage,
            category: AuditCategory.exportFinished,
            message: "会话数据已导出",
            metadata: [
                "sessionCount": String(sessionCount),
                "bytes": String(bytes),
            ]
        )
    }

    func auditExportFailed() {
        audit.record(
            domain: .storage,
            severity: .warning,
            category: AuditCategory.exportFinished,
            message: "会话数据导出失败"
        )
    }

    func auditExportSessionFinished(sessionID: UUID, bytes: Int) {
        audit.record(
            domain: .storage,
            category: AuditCategory.exportFinished,
            message: "单个会话已导出",
            sessionID: sessionID,
            metadata: ["bytes": String(bytes)]
        )
    }

    func auditImportStarted(bytes: Int) {
        audit.record(
            domain: .storage,
            category: AuditCategory.importStarted,
            message: "会话导入开始",
            metadata: ["bytes": String(bytes)]
        )
    }

    func auditImportFinished(sessions: Int, messages: Int) {
        audit.record(
            domain: .storage,
            category: AuditCategory.importFinished,
            message: "会话导入完成",
            metadata: [
                "importedSessions": String(sessions),
                "importedMessages": String(messages),
            ]
        )
    }

    func auditImportFailed(reason: String) {
        audit.record(
            domain: .storage,
            severity: .warning,
            category: AuditCategory.importFinished,
            message: "会话导入失败",
            metadata: ["reason": reason]
        )
    }
}
