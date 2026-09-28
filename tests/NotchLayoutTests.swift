import XCTest

@MainActor
final class NotchLayoutTests: XCTestCase {
    func testReferenceMeasurementsAndCellContainment() throws { try NotchChecks.layout() }
    func testCardBoundsAndTailAlignment() throws { try NotchChecks.geometry() }
}
