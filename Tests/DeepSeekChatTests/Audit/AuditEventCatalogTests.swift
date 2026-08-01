import XCTest

@testable import DeepSeekChat

/// AU-1：事件目录 ≥ 40 种、唯一、命名规范，与 ADR-0009 附录一致。
final class AuditEventCatalogTests: XCTestCase {
    func testCatalogHasAtLeastFortyCategoriesAU1() {
        XCTAssertGreaterThanOrEqual(
            AuditCategory.all.count, 40,
            "AU-1：事件目录应 ≥ 40 种（ADR-0009 附录 70 种）"
        )
    }

    func testCatalogCategoriesAreUniqueAU1() {
        XCTAssertEqual(
            Set(AuditCategory.all).count, AuditCategory.all.count,
            "AU-1：事件目录不得重复"
        )
    }

    func testCatalogCategoriesFollowNamingConventionAU1() {
        let pattern = #"^[A-Za-z]+\.[A-Za-z]+$"#
        for category in AuditCategory.all {
            XCTAssertNotNil(
                category.range(of: pattern, options: .regularExpression),
                "AU-1：目录命名应为 域.事件（实际：\(category)）"
            )
        }
    }

    func testWiredCategoriesBelongToCatalogAU1() {
        let wired: [String] = [
            AuditCategory.apiKeyWritten, AuditCategory.apiKeyDeleted,
            AuditCategory.providerEnabledChanged, AuditCategory.modelChanged,
            AuditCategory.toolToggleChanged, AuditCategory.corpusAdded,
            AuditCategory.corpusRemoved, AuditCategory.corpusToggled,
            AuditCategory.deliberationDurationChanged, AuditCategory.corpusAuthorized,
            AuditCategory.pathContained, AuditCategory.pathDenied,
            AuditCategory.registrySelfCheckPassed, AuditCategory.registryViolation,
            AuditCategory.roundLimitEnforced, AuditCategory.executionStart,
            AuditCategory.executionSuccess, AuditCategory.executionFailed,
            AuditCategory.notRegistered, AuditCategory.migrationApplied,
            AuditCategory.migrationFailed, AuditCategory.dbFallbackToMemory,
            AuditCategory.exportFinished, AuditCategory.importStarted,
            AuditCategory.importFinished, AuditCategory.sessionDeleted,
        ]
        let catalog = Set(AuditCategory.all)
        for category in wired {
            XCTAssertTrue(
                catalog.contains(category),
                "AU-1：已接入目录 \(category) 必须在事件目录中"
            )
        }
    }
}
