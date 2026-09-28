import XCTest

final class HistoryInsightTests: XCTestCase {
    func testEvidenceAndEligibility() throws { try HistoryInsightChecks.run() }
}
