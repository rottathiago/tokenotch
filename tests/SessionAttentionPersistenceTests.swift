import XCTest

@MainActor
final class SessionAttentionPersistenceTests: XCTestCase {
    func testConsentRestartAndPrivateDeletion() throws { try SessionAttentionChecks.persistence() }
    func testBoundedLifecycle() throws { try SessionAttentionChecks.lifecycle() }
    func testAttentionRequestsAndPolicy() throws { try SessionAttentionChecks.requests() }
    func testNotificationRouting() throws { try SessionAttentionChecks.notificationRouting() }
    func testActualExposure() throws { try SessionAttentionChecks.exposure() }
    func testRequestExposureAndExactDismissalThreshold() throws { try SessionAttentionChecks.requestExposure() }
    func testRequestScopedDismissalAndPersistence() throws { try SessionAttentionChecks.requestDismissal() }
    func testRequestDismissalInRealCard() throws { try SessionAttentionChecks.requestCard() }
    func testRequestHoverAcknowledgesWithoutAnyClick() throws { try SessionAttentionChecks.requestHoverCard() }
    func testIndependentRequestRowButtons() throws { try SessionAttentionChecks.requestRowButtons() }
    func testRequestDwellResetsWhenScrolledOut() throws { try SessionAttentionChecks.requestScrollVisibility() }
    func testPrioritiesAndAccessibleColors() throws { try SessionAttentionChecks.presentation() }
    func testCloseAcknowledgment() throws { try SessionAttentionChecks.closeAcknowledgment() }
    func testQuickHoverAcknowledgesOnClose() throws { try SessionAttentionChecks.quickHoverCard() }
    func testRealVisibleCard() throws { try SessionAttentionChecks.visibleCard() }
}
