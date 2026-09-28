import XCTest

@MainActor
final class NotchPresentationTests: XCTestCase {
    func testQuotaAndLocalObservationSemantics() throws { try NotchChecks.presentation() }
}
