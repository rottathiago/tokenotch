import XCTest

@MainActor
final class ProductionAppTests: XCTestCase {
    func testResumableSetupAndExplicitReleaseCheck() throws { try ProductionAppChecks.run() }
}
