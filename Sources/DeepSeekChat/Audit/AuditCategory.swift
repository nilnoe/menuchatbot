import Foundation

/// 事件目录（ADR-0009 附录，70 种；与文档同步维护，AU-1 断言 ≥ 40 且唯一）。
enum AuditCategory {
    // MARK: A config（11）
    static let apiKeyWritten = "config.apiKeyWritten"
    static let apiKeyDeleted = "config.apiKeyDeleted"
    static let providerEnabledChanged = "config.providerEnabledChanged"
    static let baseURLChanged = "config.baseURLChanged"
    static let modelChanged = "config.modelChanged"
    static let toolToggleChanged = "config.toolToggleChanged"
    static let corpusAdded = "config.corpusAdded"
    static let corpusRemoved = "config.corpusRemoved"
    static let corpusToggled = "config.corpusToggled"
    static let deliberationDurationChanged = "config.deliberationDurationChanged"
    static let systemPromptChanged = "config.systemPromptChanged"

    // MARK: B permission（10）
    static let corpusAuthorized = "permission.corpusAuthorized"
    static let corpusRestored = "permission.corpusRestored"
    static let bookmarkStale = "permission.bookmarkStale"
    static let pathContained = "permission.pathContained"
    static let pathDenied = "permission.pathDenied"
    static let registrySelfCheckPassed = "permission.registrySelfCheckPassed"
    static let registryViolation = "permission.registryViolation"
    static let roundLimitEnforced = "permission.roundLimitEnforced"
    static let confirmGateShown = "permission.confirmGateShown"
    static let confirmGateDenied = "permission.confirmGateDenied"

    // MARK: C tool（12）
    static let executionStart = "tool.executionStart"
    static let executionSuccess = "tool.executionSuccess"
    static let executionFailed = "tool.executionFailed"
    static let executionTimedOut = "tool.executionTimedOut"
    static let executionCancelled = "tool.executionCancelled"
    static let notRegistered = "tool.notRegistered"
    static let readFileExtensionRejected = "tool.readFileExtensionRejected"
    static let readFileSizeTruncated = "tool.readFileSizeTruncated"
    static let sandboxProfileApplied = "tool.sandboxProfileApplied"
    static let sandboxNetworkDenied = "tool.sandboxNetworkDenied"
    static let sandboxWriteDenied = "tool.sandboxWriteDenied"
    static let sandboxEnvCleared = "tool.sandboxEnvCleared"

    // MARK: D storage（11）
    static let migrationApplied = "storage.migrationApplied"
    static let migrationFailed = "storage.migrationFailed"
    static let dbFallbackToMemory = "storage.dbFallbackToMemory"
    static let exportStarted = "storage.exportStarted"
    static let exportFinished = "storage.exportFinished"
    static let importStarted = "storage.importStarted"
    static let importFinished = "storage.importFinished"
    static let sessionDeleted = "storage.sessionDeleted"
    static let indexRebuildStarted = "storage.indexRebuildStarted"
    static let indexRebuildFinished = "storage.indexRebuildFinished"
    static let indexUnavailable = "storage.indexUnavailable"

    // MARK: E ffi + supplyChain（7）
    static let ffiCalled = "ffi.called"
    static let ffiError = "ffi.error"
    static let ffiPanic = "ffi.panic"
    static let ffiLeakDetected = "ffi.leakDetected"
    static let ffiSnapshotCollected = "ffi.snapshotCollected"
    static let supplyChainAuditFailed = "supplyChain.cargoAuditFailed"
    static let supplyChainABIFailed = "supplyChain.abiCheckFailed"

    // MARK: F network（9）
    static let requestStarted = "network.requestStarted"
    static let requestFinished = "network.requestFinished"
    static let requestFailed = "network.requestFailed"
    static let requestCancelled = "network.requestCancelled"
    static let retryStarted = "network.retryStarted"
    static let sseParseError = "network.sseParseError"
    static let usageRecorded = "network.usageRecorded"
    static let searchTriggered = "network.searchTriggered"
    static let searchSourcesReturned = "network.searchSourcesReturned"

    // MARK: G deliberation（10；domain 归 network）
    static let deliberationStarted = "deliberation.started"
    static let deliberationPhaseChanged = "deliberation.phaseChanged"
    static let deliberationBudgetExceeded = "deliberation.budgetExceeded"
    static let deliberationCostEstimated = "deliberation.costEstimated"
    static let deliberationStopped = "deliberation.stopped"
    static let deliberationResumed = "deliberation.resumed"
    static let deliberationVerifyPassed = "deliberation.verifyPassed"
    static let deliberationVerifyFailed = "deliberation.verifyFailed"
    static let deliberationCostGuarded = "deliberation.costGuarded"
    static let deliberationPartialKept = "deliberation.partialKept"

    /// 全部目录（与 ADR-0009 附录一致；AU-1 断言）。
    static let all: [String] = [
        // A config
        apiKeyWritten, apiKeyDeleted, providerEnabledChanged, baseURLChanged, modelChanged,
        toolToggleChanged, corpusAdded, corpusRemoved, corpusToggled,
        deliberationDurationChanged, systemPromptChanged,
        // B permission
        corpusAuthorized, corpusRestored, bookmarkStale, pathContained, pathDenied,
        registrySelfCheckPassed, registryViolation, roundLimitEnforced, confirmGateShown,
        confirmGateDenied,
        // C tool
        executionStart, executionSuccess, executionFailed, executionTimedOut,
        executionCancelled, notRegistered, readFileExtensionRejected, readFileSizeTruncated,
        sandboxProfileApplied, sandboxNetworkDenied, sandboxWriteDenied, sandboxEnvCleared,
        // D storage
        migrationApplied, migrationFailed, dbFallbackToMemory, exportStarted, exportFinished,
        importStarted, importFinished, sessionDeleted, indexRebuildStarted, indexRebuildFinished,
        indexUnavailable,
        // E ffi + supplyChain
        ffiCalled, ffiError, ffiPanic, ffiLeakDetected, ffiSnapshotCollected,
        supplyChainAuditFailed, supplyChainABIFailed,
        // F network
        requestStarted, requestFinished, requestFailed, requestCancelled, retryStarted,
        sseParseError, usageRecorded, searchTriggered, searchSourcesReturned,
        // G deliberation
        deliberationStarted, deliberationPhaseChanged, deliberationBudgetExceeded,
        deliberationCostEstimated, deliberationStopped, deliberationResumed,
        deliberationVerifyPassed, deliberationVerifyFailed, deliberationCostGuarded,
        deliberationPartialKept,
    ]
}
