import XCTest

@MainActor
final class NotchRenderTests: XCTestCase {
    func testPerSessionContextMeters() throws { try ContextNotchChecks.run() }
    func testUsageTimelineStatesAndLayout() throws { try UsageTimelineNotchChecks.run() }
    func testSectionHeadingsAcrossStatesAndScales() throws { try NotchChecks.sectionHeadings() }
    func testNotchAndCardFixtures() throws { try NotchChecks.render() }
}
