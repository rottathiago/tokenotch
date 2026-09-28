import XCTest

final class SessionTimelineTests: XCTestCase {
    func testPersistenceAndPrivacy() throws { try TimelineChecks.persistence() }
    func testRetentionCapsAndPagination() throws { try TimelineChecks.limits() }
    func testObservedOrderingAndCapabilities() throws { try TimelineChecks.ordering() }
    func testStorageFailures() throws { try TimelineChecks.failures() }
    @MainActor func testConsentLifecycle() async throws { try await TimelineLifecycleChecks.run() }
}
