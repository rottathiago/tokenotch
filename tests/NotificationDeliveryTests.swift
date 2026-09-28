import XCTest

@MainActor
final class NotificationDeliveryTests: XCTestCase {
    func testIndependentDeliveryChannels() throws { try NotificationDeliveryChecks.channels() }
    func testMultiDisplayNotificationCards() throws { try NotificationDeliveryChecks.displays() }
}
