import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    func testLifecycleAndConsent() throws { try OnboardingChecks.lifecycle() }
    func testEligibilityAndApprovalRecovery() throws { try OnboardingChecks.eligibilityAndRecovery() }
    func testFailedInstallationAndMigration() throws { try OnboardingChecks.failedInstallAndMigration() }
    func testWizardRendering() throws { try OnboardingChecks.render() }
    func testInlineConnectionStates() throws { try OnboardingChecks.connectionStates() }
    func testWizardNavigation() throws { try OnboardingChecks.interaction() }
}
