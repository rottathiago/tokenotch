import TokenotchCore
import XCTest

final class TelemetryTests: XCTestCase {
    func testUsageContractAndReceiverAdmission() throws {
        try TelemetryChecks.run()
    }

    @MainActor func testNativeSetupRequestUsesWholeUnixSeconds() throws {
        try VSCodeIntegrationChecks.setupRequest()
    }

    @MainActor func testTerraUsageReachesLiveAndSavedNotchModels() throws {
        try VSCodeIntegrationChecks.modelUsage("gpt-5.6-terra")
    }

    @MainActor func testSolUsageReachesLiveAndSavedNotchModelsThroughAgentHostRoute() throws {
        try VSCodeIntegrationChecks.modelUsage("gpt-5.6-sol")
    }

    @MainActor func testReceiverErrorsRecoverWithoutHidingCoverageOrSetupErrors() async throws {
        try await VSCodeIntegrationChecks.receiverErrorRecovery()
    }
}
