import Foundation
import TokenotchCore
import XCTest

final class DeveloperMetricsTests: XCTestCase {
    func testContextLifecycle() throws { try ContextChecks.run() }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func usage(_ session: String, _ call: String, model: String? = nil,
                       input: Int64 = 10, output: Int64 = 2, cacheInput: Int64 = 0, date: Date) -> ActivityEvent {
        ActivityEvent(source: .cli, session: ActivityEvent.digest(session), kind: .usage, timestamp: date,
                      tokens: TokenUsage(callID: ActivityEvent.digest("\(session):\(call)"),
                                         input: input, output: output, cacheInput: cacheInput, model: model))
    }

    private func context(_ session: String, current: Int64, limit: Int64 = 100, date: Date) -> ActivityEvent {
        ActivityEvent(source: .cli, session: ActivityEvent.digest(session), kind: .context, timestamp: date,
                      context: ContextUsage(currentTokens: current, tokenLimit: limit))
    }

    func testGroupsCallsBySessionAndModelWithoutDoubleCounting() throws {
        var ledger = TokenLedger()
        let first = usage("one", "same", model: "model-a", date: now)
        try ledger.observe(first, now: now)
        try ledger.observe(first, now: now)
        try ledger.observe(usage("two", "same", model: "model-b", input: 20, cacheInput: 15, date: now), now: now)
        try ledger.observe(usage("one", "other", date: now), now: now)
        XCTAssertEqual(ledger.totals?.calls, 3)
        XCTAssertEqual(ledger.totals?.input, 40)
        XCTAssertEqual(ledger.totals?.output, 6)
        XCTAssertEqual(ledger.totals?.cacheInput, 15)
        XCTAssertEqual(ledger.totals?.total, 61)
        XCTAssertEqual(ledger.bySession.count, 2)
        XCTAssertEqual(ledger.bySession.first { $0.id == ActivityEvent.digest("one") }?.tokens?.calls, 2)
        XCTAssertEqual(ledger.byModel.count, 3)
        XCTAssertEqual(ledger.byModel.first?.model, "model-b")
        XCTAssertEqual(ledger.byModel.first { $0.model == nil }?.title, "Model unavailable")
        XCTAssertEqual(ledger.byModel.reduce(0) { $0 + $1.tokens.input }, ledger.totals?.input)
    }

    func testTodayUsesLocalCalendarAndExcludesYesterdayAndFuture() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = ISO8601DateFormatter().date(from: "2026-09-20T07:01:00Z")!
        var ledger = TokenLedger()
        try ledger.observe(usage("one", "yesterday", date: date.addingTimeInterval(-90)), now: date)
        try ledger.observe(usage("one", "today", date: date), now: date)
        try ledger.observe(usage("one", "future", date: date.addingTimeInterval(20)), now: date)
        XCTAssertEqual(ledger.today(now: date, calendar: calendar)?.calls, 1)
        XCTAssertEqual(ledger.todayByModel(now: date, calendar: calendar).reduce(0) { $0 + $1.tokens.calls }, 1)
        XCTAssertEqual(ledger.totals?.calls, 3)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date)!
        XCTAssertNil(ledger.today(now: tomorrow, calendar: calendar))
        XCTAssertTrue(ledger.todayByModel(now: tomorrow, calendar: calendar).isEmpty)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(ledger.today(now: date, calendar: calendar)?.calls, 2)
        XCTAssertEqual(ledger.todayByModel(now: date, calendar: calendar).reduce(0) { $0 + $1.tokens.calls }, 2)
    }

    func testTodayHonorsDSTCalendarBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = ISO8601DateFormatter().date(from: "2026-11-01T06:01:00Z")!
        let firstHour = ISO8601DateFormatter().date(from: "2026-11-01T05:59:00Z")!
        var ledger = TokenLedger()
        try ledger.observe(usage("one", "before-fallback", date: firstHour), now: firstHour)
        try ledger.observe(usage("one", "after-fallback", date: date), now: date)
        XCTAssertEqual(ledger.today(now: date, calendar: calendar)?.calls, 2)
        XCTAssertEqual(ledger.todayByModel(now: date, calendar: calendar).reduce(0) { $0 + $1.tokens.calls }, 2)
    }

    func testContextOnlyDoesNotInventTokensOrActivityAndIgnoresOlderReadings() throws {
        var ledger = TokenLedger()
        let event = context("one", current: 80, date: now)
        try ledger.observe(event, now: now)
        try ledger.observe(context("one", current: 20, date: now.addingTimeInterval(-1)), now: now)
        try ledger.observe(context("one", current: 30, date: now), now: now)
        XCTAssertNil(ledger.totals)
        XCTAssertTrue(ledger.byModel.isEmpty)
        let item = try XCTUnwrap(ledger.bySession.first)
        XCTAssertNil(item.tokens)
        XCTAssertEqual(item.context?.usage.fraction, 0.8)
        XCTAssertEqual(item.context?.isStale(now: now.addingTimeInterval(300)), false)
        XCTAssertEqual(item.context?.isStale(now: now.addingTimeInterval(301)), true)
        var activity = ActivityState()
        XCTAssertThrowsError(try activity.accept(event, now: now))
        XCTAssertNil(Notice.activity(event))
        try ledger.observe(context("one", current: 10, date: now.addingTimeInterval(1)), now: now)
        XCTAssertEqual(ledger.bySession.first?.context?.usage.currentTokens, 10)
        try ledger.observe(usage("one", "call", date: now), now: now)
        XCTAssertEqual(ledger.bySession.count, 1)
        XCTAssertEqual(ledger.bySession.first?.tokens?.calls, 1)
    }

    func testRetentionBoundsAndExpiry() throws {
        var ledger = TokenLedger()
        for index in 0..<4097 {
            let date = now.addingTimeInterval(Double(index) / 100)
            try ledger.observe(usage("one", "\(index)", date: date), now: date)
        }
        XCTAssertEqual(ledger.totals?.calls, 4096)
        XCTAssertEqual(ledger.lastDiscardedAt, now)
        for index in 0..<101 {
            let date = now.addingTimeInterval(Double(index))
            try ledger.observe(context("\(index)", current: 1, date: date), now: date)
        }
        XCTAssertEqual(ledger.bySession.filter { $0.context != nil }.count, 100)
        XCTAssertFalse(ledger.bySession.contains { $0.id == ActivityEvent.digest("0") })
        ledger.expire(now: now.addingTimeInterval(86_500))
        XCTAssertNil(ledger.totals)
        XCTAssertNil(ledger.lastDiscardedAt)
        XCTAssertTrue(ledger.bySession.isEmpty)
        XCTAssertTrue(ledger.byModel.isEmpty)
    }

    func testNormalizerStripsContentAndValidatesOptionalModelAndContext() throws {
        let base: [String: Any] = ["usageContract": 1, "sessionId": "private-session",
                                  "timestamp": now.timeIntervalSince1970 * 1000, "eventId": "call",
                                  "prompt": "private-prompt", "cwd": "/private/workspace"]
        func normalize(_ values: [String: Any], hook: String) throws -> ActivityEvent {
            let data = try JSONSerialization.data(withJSONObject: base.merging(values) { _, new in new })
            return try HookNormalizer.normalize(data, source: .cli, hook: hook, now: now)
        }
        let event = try normalize(["inputTokens": 10, "outputTokens": 2, "cacheReadTokens": 8,
                                   "model": "vendor/model-1.0"], hook: "usage")
        XCTAssertEqual(event.tokens?.model, "vendor/model-1.0")
        XCTAssertEqual(event.tokens?.cacheInput, 8)
        XCTAssertEqual(event.tokens?.input, 2)
        let context = try normalize(["currentTokens": 80, "tokenLimit": 100], hook: "context")
        XCTAssertEqual(context.context?.fraction, 0.8)
        for item in [event, context] {
            let data = try JSONEncoder().encode(item)
            XCTAssertEqual(try JSONDecoder().decode(ActivityEvent.self, from: data), item)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        }
        for invalid in [true, -1, 1.5, "1", NSNull(), 1_000_000_001] as [Any] {
            XCTAssertThrowsError(try normalize(["currentTokens": invalid, "tokenLimit": 100], hook: "context"))
            XCTAssertThrowsError(try normalize(["currentTokens": 1, "tokenLimit": invalid], hook: "context"))
        }
        XCTAssertThrowsError(try normalize(["currentTokens": 0, "tokenLimit": 0], hook: "context"))
        for model in ["", "bad model", "bad\nmodel", String(repeating: "a", count: 129), NSNull(), 12] as [Any] {
            XCTAssertThrowsError(try normalize(["inputTokens": 1, "outputTokens": 1, "model": model], hook: "usage"))
        }
        for invalid in [true, -1, 1.5, "1", NSNull(), 1_000_000_001] as [Any] {
            XCTAssertThrowsError(try normalize(["inputTokens": 1, "outputTokens": 1,
                                                "cacheReadTokens": invalid], hook: "usage"))
        }
        XCTAssertNil(try normalize(["inputTokens": 0, "outputTokens": 0], hook: "usage").tokens?.model)
        XCTAssertEqual(try normalize(["inputTokens": 0, "outputTokens": 0], hook: "usage").tokens?.cacheInput, 0)
        XCTAssertEqual(try normalize(["currentTokens": 120, "tokenLimit": 100], hook: "context").context?.fraction, 1.2)
    }

    func testMetricPayloadsCannotMasqueradeAsActivityOrOtherClient() {
        let tokens = TokenUsage(callID: ActivityEvent.digest("call"), input: 1, output: 1)
        let context = ContextUsage(currentTokens: 10, tokenLimit: 100)
        let key = ActivityEvent.digest("session")
        for event in [
            ActivityEvent(source: .vscode, session: key, kind: .context, timestamp: now, context: context),
            ActivityEvent(source: .cli, session: key, kind: .stopped, timestamp: now, context: context),
            ActivityEvent(source: .cli, session: key, kind: .usage, timestamp: now, tokens: tokens, context: context),
            ActivityEvent(source: .cli, session: key, kind: .context, timestamp: now, tokens: tokens),
            ActivityEvent(source: .cli, session: key, kind: .context, timestamp: now),
        ] {
            XCTAssertThrowsError(try event.validate(now: now))
        }
    }
}
