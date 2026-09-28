import XCTest

@MainActor
final class NotchInteractionTests: XCTestCase {
    func testHoverPinningAndTimedReveal() throws { try NotchChecks.interactions() }
    func testFocusHitTestingAndWindowLifecycle() throws { try NotchChecks.windows() }
    func testIdleAutoHideAndHoverExpansion() throws { try NotchChecks.autoHide() }
    func testAutoHidePreferencesMigration() throws { try NotchChecks.preferences() }
}
