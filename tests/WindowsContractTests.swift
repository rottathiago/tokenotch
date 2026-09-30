import XCTest

final class WindowsContractTests: XCTestCase {
    func testSharedHookContracts() throws {
        try WindowsContractChecks.run()
    }
}
