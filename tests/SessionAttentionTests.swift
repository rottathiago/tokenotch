import Foundation
import TokenotchCore
import XCTest

final class SessionAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ kind: EventKind, at offset: Double = 0, session: String = "one",
                       source: Client = .cli, fraction: Int64 = 85,
                       success: Bool? = nil) -> ActivityEvent {
        ActivityEvent(source: source, session: ActivityEvent.digest(session), kind: kind,
            timestamp: now.addingTimeInterval(offset),
            context: kind == .context ? ContextUsage(currentTokens: fraction, tokenLimit: 100) : nil,
            compaction: kind == .compaction ? CompactionUsage(success: success, after: success == true ? 20 : nil) : nil,
            metricID: kind == .compaction ? ActivityEvent.digest("compaction-\(offset)") : nil)
    }

    private func observe(_ event: ActivityEvent, into state: inout SessionAttentionState) throws {
        try state.observe(event, now: event.timestamp)
    }

    func testViewedErrorNeedsExplicitWorkOrDismissalNotHeartbeat() throws {
        var state = SessionAttentionState()
        try observe(event(.failed), into: &state)
        let id = try XCTUnwrap(state.notices.first?.id)
        state.markViewed([id], now: now)
        XCTAssertTrue(state.notices[0].needsHighlight)
        try observe(event(.active, at: 30), into: &state)
        try observe(event(.idle, at: 60), into: &state)
        XCTAssertEqual(state.notices[0].disposition, .pending)
        state.prune(now: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(state.notices.count, 1)
        try observe(event(.working, at: 90), into: &state)
        XCTAssertEqual(state.notices[0].disposition, .superseded)
        try observe(event(.failed, at: 100), into: &state)
        XCTAssertNotEqual(state.notices[0].id, id)
        XCTAssertNil(state.notices[0].viewedAt)
        state.markViewed([id], now: now)
        XCTAssertNil(state.notices[0].viewedAt)
    }

    func testStopIsInformationalAndSourceQualified() throws {
        var state = SessionAttentionState()
        try observe(event(.stopped), into: &state)
        try observe(event(.stopped, source: .vscode), into: &state)
        XCTAssertEqual(Set(state.notices.map(\.sessionID)).count, 2)
        state.markViewed([state.notices[0].id], now: now)
        XCTAssertEqual(state.notices.filter(\.needsHighlight).count, 1)
        try observe(event(.active, at: 10), into: &state)
        XCTAssertEqual(state.notices.first { $0.source == .cli }?.disposition, .superseded)
        XCTAssertEqual(state.notices.first { $0.source == .vscode }?.disposition, .pending)
    }

    func testContextEpisodesAndCompactionEvidence() throws {
        var state = SessionAttentionState()
        try observe(event(.context), into: &state)
        let id = state.notices[0].id
        state.dismiss([id])
        try observe(event(.context, at: 10), into: &state)
        XCTAssertEqual(state.notices[0].id, id)
        XCTAssertEqual(state.notices[0].disposition, .dismissed)
        try observe(event(.context, at: 20, fraction: 79), into: &state)
        XCTAssertEqual(state.notices[0].disposition, .resolved)
        try observe(event(.context, at: 30), into: &state)
        XCTAssertNotEqual(state.notices[0].id, id)
        try observe(event(.compaction, at: 40, success: false), into: &state)
        try observe(event(.active, at: 50), into: &state)
        XCTAssertEqual(state.notices.filter(\.needsHighlight).count, 2)
        try observe(event(.compaction, at: 60, success: true), into: &state)
        XCTAssertTrue(state.notices.allSatisfy { $0.disposition == .resolved })
    }

    func testOrderingTerminalBoundaryAndReplay() throws {
        var state = SessionAttentionState()
        let high = event(.context, at: 30)
        try observe(high, into: &state)
        XCTAssertFalse(try state.observe(high, now: high.timestamp))
        try observe(event(.context, at: 20, fraction: 10), into: &state)
        XCTAssertEqual(state.notices[0].disposition, .pending)
        try observe(event(.failed, at: 40), into: &state)
        try observe(event(.context, at: 50), into: &state)
        XCTAssertEqual(state.notices.first { $0.kind == .context }?.disposition, .superseded)
        try observe(event(.working, at: 60), into: &state)
        try observe(event(.context, at: 55), into: &state)
        XCTAssertEqual(state.notices.first { $0.kind == .context }?.disposition, .superseded)
        try observe(event(.context, at: 70), into: &state)
        XCTAssertEqual(state.notices.first { $0.kind == .context }?.disposition, .pending)
    }

    func testBoundsAndPrivateRoundTrip() throws {
        var state = SessionAttentionState()
        for index in 0..<101 {
            try observe(event(.failed, session: "session-\(index)"), into: &state)
        }
        XCTAssertEqual(state.sessionCount, 100)
        XCTAssertEqual(state.evictedSessions, 1)
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(ActivityEvent.digest("session-1")))
        let restored = try JSONDecoder().decode(SessionAttentionState.self, from: data)
        try restored.validate()
        XCTAssertEqual(restored.notices, state.notices)
        XCTAssertEqual(restored.sessionID(source: .cli, hash: "x"), state.sessionID(source: .cli, hash: "x"))
    }
}
