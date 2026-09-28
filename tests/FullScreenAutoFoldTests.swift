import AppKit
import XCTest
@testable import Tokenotch

final class FullScreenAutoFoldTests: XCTestCase {
    @MainActor func testFullScreenDetectionIsPerDisplay() throws {
        try NotchChecks.fullScreenDetection()
    }

    @MainActor func testVisibilityFollowsFullScreenTransitions() throws {
        try NotchChecks.fullScreenVisibility()
    }

    func testFullScreenAndNotchedDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertTrue(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 123,
            windows: [(123, 0, screen)]))
        XCTAssertTrue(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 123,
            windows: [(123, 0, CGRect(x: 0, y: 44, width: 1728, height: 1073))], safeAreaTopInset: 44))
    }
    func testWindowAndBackgroundAppDoNotCountAsFullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertFalse(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 123,
            windows: [(123, 0, CGRect(x: 100, y: 100, width: 1000, height: 800))]))
        XCTAssertFalse(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 123,
            windows: [(456, 0, screen), (123, 24, screen)]))
    }
}
