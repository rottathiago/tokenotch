import XCTest

@MainActor
final class ConnectionsTests: XCTestCase {
    func testCapabilityReadiness() throws { try ConnectionsChecks.readiness() }
    func testGuidedSetupConsentAndRecovery() throws { try ConnectionsChecks.setup() }
    func testConnectionsAndSetupRendering() throws { try ConnectionsChecks.render() }
    func testIndependentNotchProviderVisibility() throws { try ConnectionsChecks.notchVisibility() }
    func testIndependentConfigurationStatuses() throws { try ConnectionsChecks.configurationStates() }
}
