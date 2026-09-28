import AppKit
import SwiftUI
import XCTest
@testable import Tokenotch

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var displayIdentifier: String? = nil
}

final class NotchGeometryTests: XCTestCase {
    func testEveryEdgeStaysFlushForFractionalSizesAndOffsetDisplays() {
        let full = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let screen = FakeScreen(frameValue: full, visibleFrameValue: full.insetBy(dx: 90, dy: 70))
        let unreserved = FakeScreen(frameValue: full, visibleFrameValue: full)
        for edge in NotchEdge.allCases {
            for offset: CGFloat in [-10000, -230, 0, 310, 10000] {
                let size = edge.isVertical ? CGSize(width: 56.325, height: 118.183) : CGSize(width: 118.183, height: 56.325)
                let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge, alongOffset: offset)
                XCTAssertEqual(frame, NotchGeometry.panelFrame(for: unreserved, panelSize: size, edge: edge, alongOffset: offset))
                XCTAssertGreaterThanOrEqual(frame.width, size.width)
                XCTAssertGreaterThanOrEqual(frame.height, size.height)
                XCTAssertTrue(full.contains(frame))
                XCTAssertEqual(frame, frame.integral)
                switch edge {
                case .left: XCTAssertEqual(frame.minX, full.minX)
                case .right: XCTAssertEqual(frame.maxX, full.maxX)
                case .top: XCTAssertEqual(frame.maxY, full.maxY)
                case .bottom: XCTAssertEqual(frame.minY, full.minY)
                }
            }
        }
    }

    func testChosenAndDisconnectedDisplaySelection() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero, displayIdentifier: "active")
        let chosen = FakeScreen(frameValue: .zero, visibleFrameValue: .zero, displayIdentifier: "chosen")
        XCTAssertEqual(NotchGeometry.preferredScreen(from: [active, chosen], preference: .display("chosen"),
                                                      activeScreen: active)?.displayIdentifier, "chosen")
        XCTAssertEqual(NotchGeometry.preferredScreen(from: [active], preference: .display("missing"),
                                                      activeScreen: active)?.displayIdentifier, "active")
    }

    func testDragDirection() {
        let screen = FakeScreen(frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrameValue: .zero)
        let size = CGSize(width: 118, height: 56)
        for edge in NotchEdge.allCases {
            let center = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge)
            let moved = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge, alongOffset: 100)
            if edge.isVertical { XCTAssertEqual(moved.midY, center.midY - 100) }
            else { XCTAssertEqual(moved.midX, center.midX + 100) }
        }
    }

    func testShapeBoundsAndCenterAtEveryEdgeAndScale() {
        for edge in NotchEdge.allCases {
            for scale in [0.75, 1, 1.5] {
                let rect = CGRect(x: 0, y: 0, width: (edge.isVertical ? 56 : 118) * scale,
                                  height: (edge.isVertical ? 118 : 56) * scale)
                let path = SideNotchShape(edge: edge).path(in: rect)
                XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
                XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
            }
        }
    }
}
