import XCTest

final class UsageReportingTests: XCTestCase {
    @MainActor func testFoundationArchivesStayProviderScoped() throws {
        try UsageReportingChecks.providerArchiveIsolation()
    }

    @MainActor func testSavedTodayMatchesNotchAndStorage() throws {
        try UsageReportingChecks.savedAndLive()
    }

    @MainActor func testLiveOnlyTodayMatchesNotch() throws {
        try UsageReportingChecks.liveOnly()
    }
}
