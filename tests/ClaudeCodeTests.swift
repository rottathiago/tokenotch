import XCTest

final class ClaudeCodeTests: XCTestCase {
    func testSessionEndPrivacyIdentityOrderingAndResume() throws { try ClaudeCodeChecks.sessionLifecycle() }
    func testSessionHooksPreserveUserSettingsAndIndependentConsent() throws { try ClaudeCodeChecks.sessionHookSetup() }
    @MainActor func testClosedSessionsDisappearWithoutLosingUsage() async throws {
        try await ClaudeCodeIntegrationChecks.sessionClosure()
    }
    func testClaudeOfficialAuthenticationPrivacyAndValidation() throws { try ClaudeCodeChecks.account() }
    func testStatusLineQuotaContextAndPrivacy() throws { try ClaudeCodeChecks.statusLine() }
    func testStatusLineOwnedSetupConflictAndRemoval() throws { try ClaudeCodeChecks.statusLineSetup() }
    @MainActor func testStatusLineBridgeApplicationAndPresentation() async throws {
        try await ClaudeCodeIntegrationChecks.statusLine()
    }
    func testOwnedSettingsSetupAndRemoval() throws { try ClaudeCodeChecks.ownedSetup() }
    func testApprovedSettingsPermissionsAndReplacementGuards() throws { try ClaudeCodeChecks.settingsPermissions() }
    func testProviderScopedDeletionPreservesOtherReceipts() throws { try ClaudeCodeChecks.providerDeletion() }
    func testAccountingAndVersionedPrivacyContract() throws { try ClaudeCodeChecks.accounting() }
    func testFractionalMicroCostPreservesModelCalls() throws { try ClaudeCodeChecks.costPrecision() }
    @MainActor func testCostAndModelUpdatesStayProviderScoped() async throws {
        try await ClaudeCodeIntegrationChecks.costAndModelUpdates()
    }
    func testProducerAdmissionAndUnsupportedCoverage() throws { try ClaudeCodeChecks.admission() }
    func testHandoffReplayAcrossLiveHistoryAndTimeline() throws { try ClaudeCodeChecks.handoff() }
    func testLegacyProviderMigrationsAndRollback() throws { try ClaudeCodeChecks.migrations() }
    func testProviderRecordingConsentMigration() throws { try ClaudeCodeChecks.consent() }
    func testSourceRecordingBaselinesAndResumeIsolation() throws { try ClaudeCodeChecks.recordingWindows() }
    func testMetricsCannotCertifyLifecycleReadiness() throws { try ClaudeCodeChecks.signalReadiness() }
    @MainActor func testApplicationCollectionAndRestart() async throws { try await ClaudeCodeIntegrationChecks.collection() }
    @MainActor func testClaudeAccountOfficialLoginAndStatus() async throws {
        try await ClaudeCodeIntegrationChecks.account()
    }
    @MainActor func testSetupPermissionApprovalAndCancellation() async throws { try await ClaudeCodeIntegrationChecks.permissionApproval() }
    @MainActor func testNotchSessionsExpireWithoutDiscardingUsage() throws {
        try ClaudeCodeIntegrationChecks.sessionFreshness()
    }
    @MainActor func testProviderCellsAndMetricsCard() throws { try ClaudeCodeIntegrationChecks.presentation(directory: nil) }
    @MainActor func testProviderCellClicksAndFullScreenFolding() throws { try ClaudeCodeIntegrationChecks.interactions() }
    @MainActor func testNativeProviderKeyboardFocus() throws { try ClaudeCodeIntegrationChecks.keyboardFocus() }
}
