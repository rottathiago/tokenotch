import XCTest

final class ProductionTests: XCTestCase {
    func testReleaseVersionAndOfficialDestination() throws { try ProductionChecks.versions() }
    func testAccountRefreshReusesExplicitSignInOnSupportedProtocols() throws { try ProductionChecks.accountLogin() }
    func testExclusivePrivateApplicationLock() throws { try ProductionChecks.applicationLock() }
    func testUnsupportedRuntimeProtocolIsRejected() throws { try ProductionChecks.protocolGating() }
}
