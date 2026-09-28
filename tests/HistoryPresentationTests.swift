import XCTest

final class HistoryPresentationTests: XCTestCase {
    @MainActor func testNativeHistoryRendering() throws {
        try NotchChecks.historyRender()
    }
}
