import XCTest

@MainActor
final class NotchWaitTests: XCTestCase {
    func testBoundedFixtureWaits() throws {
        try NotchChecks.waits()
    }
}
