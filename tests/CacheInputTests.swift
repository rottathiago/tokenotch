import XCTest

final class CacheInputTests: XCTestCase {
    func testDisjointAccountingEndToEnd() throws { try CacheInputChecks.accounting() }
    func testReportingContract() throws { try CacheInputChecks.contracts() }
    func testLiveCoverage() throws { try CacheInputChecks.aggregation() }
    func testPersistentCoverage() throws { try CacheInputChecks.persistence() }
    func testLegacyMigration() throws { try CacheInputChecks.migration() }
    func testTimelineCoverage() throws { try CacheInputChecks.timeline() }
    func testLegacyTimelineAccounting() throws { try CacheInputChecks.legacyTimeline() }
    func testAccountingMigrationRollback() throws { try CacheInputChecks.migrationRollback() }
}
