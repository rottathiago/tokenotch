import XCTest

final class UsageTimelineTests: XCTestCase {
    func testCalendarBuckets() throws { try UsageTimelineChecks.calendars() }
    func testLiveBucketsAndCache() throws { try UsageTimelineChecks.live() }
    func testSavedBucketsAndRestart() throws { try UsageTimelineChecks.storage() }
    func testMigrationAtomicityAndRetention() throws { try UsageTimelineChecks.migrationAndRetention() }
    func testRecordingCoverageAndWeek() throws { try UsageTimelineChecks.coverageAndWeek() }
}
