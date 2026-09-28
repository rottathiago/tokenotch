import XCTest

final class HistoryLifecycleTests: XCTestCase {
    @MainActor func testConsentPauseRestartRemovalAndDelete() async throws {
        try await HistoryLifecycleChecks.run()
    }
}
