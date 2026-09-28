import XCTest

final class UsageHistoryTests: XCTestCase {
    func testPersistentAggregatesAndRestartDeduplication() throws { try HistoryChecks.persistence() }
    func testLatencyAndCompactionContracts() throws { try HistoryChecks.contracts() }
    func testCalendarComparisons() throws { try HistoryChecks.calendars() }
    func testNotchHistoryComparisons() throws { try HistoryChecks.notchSummary() }
    func testContextWarningPolicy() throws { try HistoryChecks.warnings() }
    func testStorageFailureAndOwnership() throws { try HistoryChecks.storageFailures() }
    func testMultiYearArchiveQueries() throws { try HistoryChecks.multiYearArchive() }
}
