import TokenotchCore
import XCTest

final class NotificationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func notice(_ id: String = "event") -> Notice {
        Notice(id: id, category: .stopped, title: "Stopped", body: "Observed")
    }
    func testDefaultsAreOptInAndQuiet() {
        let preferences = NotificationPreferences()
        XCTAssertFalse(preferences.enabled)
        XCTAssertTrue(preferences.desktop)
        XCTAssertFalse(preferences.sound)
        XCTAssertFalse(preferences.expandNotch)
        XCTAssertFalse(preferences.categories.contains(.attention))
    }

    func testRequestsUseOptInCategoryAndGenericSessionTarget() throws {
        var preferences = NotificationPreferences()
        preferences.enabled = true
        var state = SessionAttentionState()
        let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("session"),
                                  kind: .inputRequested, timestamp: now)
        try state.observe(event, now: now)
        let sessionNotice = try XCTUnwrap(state.notice(for: event))
        let notice = try XCTUnwrap(Notice.activity(event, sessionNotice: sessionNotice))
        XCTAssertEqual(notice.category, .attention)
        XCTAssertEqual(notice.target?.sessionID, sessionNotice.sessionID)
        XCTAssertFalse(notice.body.contains(event.session))
        var ledger = NotificationLedger()
        XCTAssertNil(ledger.evaluate(notice, preferences: preferences, now: now))
        preferences.categories.insert(.attention)
        XCTAssertNil(ledger.evaluate(notice, preferences: preferences, now: now))
        let restored = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(NotificationPreferences()))
        XCTAssertFalse(restored.categories.contains(.attention))
    }

    func testErrorEpisodeConsumesBothReportsAcrossLedgerRestart() throws {
        var preferences = NotificationPreferences()
        preferences.enabled = true
        var state = SessionAttentionState()
        var ledger = NotificationLedger()
        let first = ActivityEvent(source: .cli, session: ActivityEvent.digest("session"),
                                  kind: .unrecoverableError, timestamp: now)
        let terminal = ActivityEvent(source: .cli, session: first.session, kind: .failed,
                                     timestamp: now.addingTimeInterval(1))
        try state.observe(first, now: now)
        let a = try XCTUnwrap(Notice.activity(first, sessionNotice: state.notice(for: first)))
        XCTAssertNotNil(ledger.evaluate(a, preferences: preferences, now: now))
        try state.observe(terminal, now: terminal.timestamp)
        let b = try XCTUnwrap(Notice.activity(terminal, sessionNotice: state.notice(for: terminal)))
        XCTAssertEqual(a.episodeID, b.episodeID)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNil(ledger.evaluate(b, preferences: preferences, now: terminal.timestamp))
        ledger = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertNil(ledger.evaluate(try XCTUnwrap(Notice.activity(terminal)), preferences: preferences, now: terminal.timestamp))
    }
    func testSnoozeConsumesEventsAndSurvivesRestartWithoutBacklog() throws {
        var preferences = NotificationPreferences()
        preferences.enabled = true
        preferences.snoozedUntil = now.addingTimeInterval(60)
        var ledger = NotificationLedger()
        XCTAssertNil(ledger.evaluate(notice(), preferences: preferences, now: now))
        let data = try JSONEncoder().encode(ledger)
        ledger = try JSONDecoder().decode(NotificationLedger.self, from: data)
        XCTAssertNil(ledger.evaluate(notice(), preferences: preferences, now: now.addingTimeInterval(61)))
        XCTAssertNotNil(ledger.evaluate(notice("new"), preferences: preferences, now: now.addingTimeInterval(61)))
        let restored = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.snoozedUntil, preferences.snoozedUntil)
    }
    func testEveryChannelObeysMasterCategoryAndManagedMute() {
        for mode in 0..<3 {
            var preferences = NotificationPreferences()
            preferences.enabled = mode != 0
            preferences.desktop = true; preferences.sound = true; preferences.expandNotch = true
            if mode == 1 { preferences.categories = [] }
            var ledger = NotificationLedger()
            XCTAssertNil(ledger.evaluate(notice(), preferences: preferences, now: now, managedMute: mode == 2))
        }
    }
    func testQuietHoursOvernightBoundariesAndDST() throws {
        var preferences = NotificationPreferences()
        preferences.quietEnabled = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let format = ISO8601DateFormatter()
        for value in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-03-08T07:30:00Z"] {
            XCTAssertTrue(preferences.isQuiet(at: try XCTUnwrap(format.date(from: value)), calendar: calendar))
        }
        XCTAssertFalse(preferences.isQuiet(at: try XCTUnwrap(format.date(from: "2026-11-01T13:00:00Z")), calendar: calendar))
        preferences.quietStart = preferences.quietEnd
        XCTAssertTrue(preferences.isQuiet(at: now, calendar: calendar))
    }
    func testIndependentChannelsAreNotCollapsed() throws {
        var preferences = NotificationPreferences()
        preferences.enabled = true; preferences.desktop = false; preferences.sound = true
        var ledger = NotificationLedger()
        let delivery = try XCTUnwrap(ledger.evaluate(notice(), preferences: preferences, now: now))
        XCTAssertFalse(delivery.desktop)
        XCTAssertTrue(delivery.sound)
        XCTAssertFalse(delivery.expand)
    }
    func testFractionalTargetsCoalesceAndDoNotRearmAfterCorrection() throws {
        let rule = try TargetRule(amount: Decimal(string: "10.5")!)
        var ledger = TargetLedger()
        func sample(_ used: String, _ tick: Double, fresh: Bool = true, cycle: String = "2026-09") -> CreditObservation {
            CreditObservation(account: "github.com:123", cycle: cycle, used: Decimal(string: used)!,
                              observedAt: now.addingTimeInterval(tick), fresh: fresh)
        }
        XCTAssertNil(ledger.evaluate(sample("0", 0), rule: rule))
        XCTAssertEqual(ledger.evaluate(sample("10.5", 1), rule: rule), 100)
        XCTAssertNil(ledger.evaluate(sample("2", 2), rule: rule))
        XCTAssertNil(ledger.evaluate(sample("10.5", 3), rule: rule))
        XCTAssertNil(ledger.evaluate(sample("11", 4, fresh: false), rule: rule))
        XCTAssertNil(ledger.evaluate(sample("11", 5, cycle: "2026-10"), rule: rule))
        let edited = try TargetRule(amount: 1)
        XCTAssertNil(ledger.evaluate(sample("11", 6), rule: edited))
    }
    func testTargetInputValidation() {
        for value in ["0", "-1", "1.00001", "NaN"] {
            if let amount = Decimal(string: value) { XCTAssertThrowsError(try TargetRule(amount: amount)) }
        }
        func testRestartSeedsEachAccountWithoutManufacturingHistoricalCrossings() throws {
            let rule = try TargetRule(amount: 100)
            var ledger = TargetLedger()
            func sample(_ account: String, _ used: Decimal, _ tick: Double) -> CreditObservation {
                CreditObservation(account: account, cycle: "2026-09", used: used,
                                  observedAt: now.addingTimeInterval(tick), fresh: true)
            }
            XCTAssertNil(ledger.evaluate(sample("one", 0, 0), rule: rule))
            XCTAssertNil(ledger.evaluate(sample("two", 0, 0), rule: rule))
            ledger = try JSONDecoder().decode(TargetLedger.self, from: JSONEncoder().encode(ledger))
            XCTAssertNil(ledger.evaluate(sample("one", 90, 1), rule: rule))
            XCTAssertNil(ledger.evaluate(sample("two", 90, 1), rule: rule))
            XCTAssertEqual(ledger.evaluate(sample("one", 100, 2), rule: rule), 100)
        }
        XCTAssertThrowsError(try TargetRule(amount: 1, thresholds: [80, 80]))
        XCTAssertThrowsError(try TargetRule(amount: 1, thresholds: [0, 101]))
        XCTAssertThrowsError(try TargetRule(amount: 1, thresholds: []))
    }
}
