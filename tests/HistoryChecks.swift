import Darwin
import Foundation
import SQLite3
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum HistoryChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(description: message)
    }
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func usage(_ id: String, at now: Date, model: String? = "test-model",
                      cacheInput: Int64 = 0, first: Double? = nil, duration: Double? = nil) -> ActivityEvent {
        ActivityEvent(source: .cli, session: ActivityEvent.digest("test-session"), kind: .usage, timestamp: now,
            tokens: TokenUsage(callID: ActivityEvent.digest(id), input: 10, output: 2,
                               cacheInput: cacheInput, model: model,
                               durationMs: duration, timeToFirstTokenMs: first))
    }
    static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-history-test-\(UUID().uuidString)")
    }
    static func context(_ count: Int64, at now: Date, session: String = "test") -> ActivityEvent {
        ActivityEvent(source: .cli, session: ActivityEvent.digest(session), kind: .context, timestamp: now,
                      context: ContextUsage(currentTokens: count, tokenLimit: 100))
    }

    static func persistence() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date("2026-09-21T12:00:00Z")
        let utc = TimeZone(secondsFromGMT: 0)!
        let calendar = HistoryCalendar(zone: utc)
        let month = calendar.interval(.month, selected: now, now: now)
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: utc, now: now)
        let a = usage("a", at: now, cacheInput: 7, first: 100, duration: 1000)
        try store!.record([a, a, usage("b", at: now, model: "other", first: 300),
                           usage("c", at: now, model: nil)], now: now)
        var snapshot = try store!.query(month)
        try require(snapshot.totals.calls == 3 && snapshot.totals.total == 43, "Duplicate receipt counted")
        try require(snapshot.totals.cacheInput == 7, "Cached input was not persisted")
        try require(snapshot.totals.meanFirstToken == 200 && snapshot.totals.firstTokenSamples == 2, "Missing latency treated as zero")
        try require(snapshot.totals.meanDuration == 1000 && snapshot.models.count == 3, "Duration/model grouping")
        try store!.heartbeat(from: now, to: now.addingTimeInterval(30), active: true)
        store = nil
        store = try UsageHistoryStore(root: root, zone: TimeZone(identifier: "Asia/Tokyo")!, now: now.addingTimeInterval(31))
        try store!.record([a], now: now.addingTimeInterval(31))
        snapshot = try store!.query(month)
        try require(snapshot.totals.calls == 3, "Restart double counted")
        try require(snapshot.zone == utc.identifier && snapshot.days.first?.gap == true, "Zone changed or interrupted recording unmarked")
        try require(snapshot.days.first?.recordingSeconds == 30, "Coverage checkpoint lost")
        try require(try store!.query(month, model: "other").totals.calls == 1, "Model filter")

        let events = (0..<4100).map { usage("many-\($0)", at: now) }
        try store!.record(events, now: now)
        snapshot = try store!.query(month)
        try require(snapshot.totals.calls == 4103, "Persistent totals inherited memory cap")
        let tomorrow = calendar.addingDays(1, to: now)
        try store!.record([usage("tomorrow", at: tomorrow)], now: tomorrow)
        let day = calendar.interval(.day, selected: now, now: now)
        try require(try store!.query(day).totals.calls == 4103, "Date query included another day")
        try require(try store!.query(month).days.count == 2, "Daily grouping")

        var info = stat()
        let path = root.appendingPathComponent("history/usage.sqlite").path
        try require(lstat(path, &info) == 0 && info.st_mode & 0o077 == 0, "Database permissions")
        let privateText = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        try require(!privateText.contains("test-session"), "Raw session persisted")
        try store!.delete()
        store = nil
        try require(!FileManager.default.fileExists(atPath: path), "Archive not deleted")
    }

    static func migration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFiles.directory(root)
        let directory = root.appendingPathComponent("history")
        try PrivateFiles.directory(directory)
        let file = directory.appendingPathComponent("usage.sqlite")
        try PrivateFiles.write(Data(), to: file)
        var database: OpaquePointer?
        try require(sqlite3_open(file.path, &database) == SQLITE_OK, "Open v1 history fixture")
        let now = date("2026-09-21T12:00:00Z")
        let schema = """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE usage (
          day TEXT NOT NULL, model TEXT NOT NULL,
          input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(input)='integer' AND input>=0),
          output INTEGER NOT NULL DEFAULT 0 CHECK(typeof(output)='integer' AND output>=0),
          calls INTEGER NOT NULL DEFAULT 0 CHECK(typeof(calls)='integer' AND calls>=0),
          first_sum REAL NOT NULL DEFAULT 0, first_count INTEGER NOT NULL DEFAULT 0,
          duration_sum REAL NOT NULL DEFAULT 0, duration_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(day, model));
        CREATE TABLE context (
          day TEXT PRIMARY KEY, maximum REAL, completed INTEGER NOT NULL DEFAULT 0,
          failed INTEGER NOT NULL DEFAULT 0, seen INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE coverage (day TEXT PRIMARY KEY, seconds REAL NOT NULL DEFAULT 0, gap INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE receipts (id TEXT PRIMARY KEY, time REAL NOT NULL);
        CREATE INDEX receipts_time ON receipts(time);
        INSERT INTO metadata VALUES ('zone','GMT'), ('began','\(now.timeIntervalSince1970)');
        PRAGMA user_version=1;
        """
        let result = sqlite3_exec(database, schema, nil, nil, nil)
        sqlite3_close(database)
        try require(result == SQLITE_OK, "Create v1 history fixture")
        let store = try UsageHistoryStore(root: root, zone: TimeZone(secondsFromGMT: 0)!, now: now)
        try store.record([usage("migrated", at: now, cacheInput: 5)], now: now)
        let snapshot = try store.query(store.clock.interval(.day, selected: now, now: now))
        try require(snapshot.totals.cacheInput == 5 && snapshot.totals.total == 17,
                    "V1 history did not migrate cached input")
    }

    static func contracts() throws {
        let now = date("2026-09-21T12:00:00Z")
        let fields: [String: Any] = ["sessionId": "private-session", "eventId": "event",
            "timestamp": now.timeIntervalSince1970 * 1000, "phase": "complete", "success": true,
            "beforeTokens": 80, "afterTokens": 20, "summaryContent": "private-summary", "checkpointPath": "/private-path"]
        let event = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: fields), source: .cli, hook: "compaction", now: now)
        try require(event.version == 2 && event.compaction?.success == true, "Compaction normalization")
        let encoded = try JSONEncoder().encode(event)
        try require(!String(decoding: encoded, as: UTF8.self).contains("private"), "Compaction content leaked")
        try require(try JSONDecoder().decode(ActivityEvent.self, from: encoded) == event, "Compaction round trip")
        try require(Notice.activity(event) == nil, "Compaction became task failure")
        var activity = ActivityState()
        try rejects("Compaction became lifecycle state") { _ = try activity.accept(event, now: now) }
        var insights = SessionInsights()
        insights.observe(event, now: now)
        let older = ActivityEvent(source: .cli, session: event.session, kind: .compaction,
            timestamp: now.addingTimeInterval(-1), compaction: CompactionUsage(success: nil), metricID: ActivityEvent.digest("start"))
        insights.observe(older, now: now)
        try require(insights.sessions.first?.compaction?.success == true, "Older start replaced completion")
        try require(insights.sessions.first?.compactionLabel(now: now.addingTimeInterval(301)) == "Compaction observation stale", "Compaction never stale")
        for latency in [-1, .infinity, .nan, 86_400_001] {
            try rejects("Invalid latency accepted") { try usage("latency", at: now, first: latency).validate(now: now) }
        }
        try usage("valid", at: now, first: 0, duration: 15.25).validate(now: now)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, now: now)
        try store.record([event, event, context(120, at: now), context(30, at: now.addingTimeInterval(1))], now: now)
        let snapshot = try store.query(store.clock.interval(.day, selected: now, now: now))
        try require(snapshot.days.first?.contextMaximum == 1.2, "Context was summed or capped")
        try require(snapshot.days.first?.compactions == 1 && snapshot.totals.calls == 0, "Compaction counted twice/as model calls")
    }

    static func calendars() throws {
        let calendar = HistoryCalendar(zone: TimeZone(identifier: "America/New_York")!)
        let spring = date("2026-03-08T12:00:00Z")
        let fall = date("2026-11-01T12:00:00Z")
        try require(calendar.interval(.day, selected: spring, now: spring).duration == 23 * 3600, "Spring DST")
        try require(calendar.interval(.day, selected: fall, now: fall).duration == 25 * 3600, "Fall DST")
        let leap = date("2024-02-29T12:00:00Z")
        try require(calendar.dayCount(calendar.interval(.month, selected: leap, now: leap)) == 29, "Leap month")
        let january = date("2026-01-03T12:00:00Z")
        let month = calendar.interval(.month, selected: january, now: january)
        let previous = calendar.prior(month, monthly: true)
        try require(calendar.key(previous.start) == "2025-12-01", "Prior year boundary")
        let (a, b) = calendar.completedComparison(month, previous, now: january, monthly: true)
        try require(calendar.dayCount(a) == 2 && calendar.dayCount(b) == 2, "Unequal elapsed comparisons")
        try require(calendar.key(b.start) == "2025-12-01", "Month comparison not calendar-aligned")
        let firstDay = date("2026-01-01T12:00:00Z")
        let firstPair = calendar.completedComparison(month, previous, now: firstDay, monthly: true)
        try require(calendar.dayCount(firstPair.0) == 0 && calendar.dayCount(firstPair.1) == 0,
                    "First-day monthly comparison invented completed days")
        let week = calendar.interval(.week, selected: january, now: january)
        let (completedWeek, previousWeek) = calendar.completedComparison(week, calendar.prior(week, monthly: false), now: january)
        try require(calendar.dayCount(completedWeek) == 6 && calendar.dayCount(previousWeek) == 6,
                    "Rolling comparison not aligned")
        try require(previousWeek.end == completedWeek.start, "Rolling comparison has an unexplained gap")
        try require(HistoryCalendar.percentage(current: 10, baseline: 0) == nil, "Zero baseline")
        try require(HistoryCalendar.percentage(current: 10, baseline: 20) == -50, "Percentage formula")
        let before = date("2026-09-21T03:59:59Z")
        let after = date("2026-09-21T04:00:00Z")
        try require(calendar.key(before) == "2026-09-20" && calendar.key(after) == "2026-09-21", "Local midnight")
    }

    static func notchSummary() throws {
        let calendar = HistoryCalendar(zone: TimeZone(identifier: "America/New_York")!)
        func snapshot(now: Date, missing: Int? = nil, gap: Int? = nil,
                      zeroBaseline: Bool = false, began: Date? = nil) throws -> HistorySnapshot {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let start = calendar.calendar.startOfDay(for: now)
            let store = try UsageHistoryStore(root: root, zone: calendar.calendar.timeZone,
                                             now: began ?? calendar.addingDays(-14, to: start))
            for offset in -14...0 where offset != missing {
                let date = calendar.addingDays(offset, to: start).addingTimeInterval(3600)
                let count: Int64 = offset == 0 ? 1_000 : offset < -7 ? (zeroBaseline ? 0 : 10) : 20
                let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("notch"),
                    kind: .usage, timestamp: date,
                    tokens: TokenUsage(callID: ActivityEvent.digest("day-\(offset)"), input: count, output: 0))
                try store.record([event], now: date)
                if offset == gap { try store.markGap(at: date) }
            }
            return try store.query(NotchHistorySummary.interval(now: now, calendar: calendar))
        }

        for text in ["2026-03-15T12:00:00Z", "2026-11-08T12:00:00Z", "2026-01-03T12:00:00Z"] {
            let now = date(text)
            try require(calendar.dayCount(NotchHistorySummary.interval(now: now, calendar: calendar)) == 15,
                        "Notch history window must use calendar days across DST/year boundaries")
            let summary = try NotchHistorySummary(snapshot: snapshot(now: now), now: now)
            try require(summary.today.total == 1_000 && summary.recent.total == 140 && summary.previous.total == 70,
                        "Notch weekly comparison included today or misaligned periods")
            try require(summary.change == 100 && summary.comparisonNote == nil, "Notch percentage formula")
            try require(summary.recentSampleDays == 7 && summary.previousSampleDays == 7, "Notch sample coverage")
            try require(summary.zone == "America/New_York", "Notch lost archive time zone")
        }
        let now = date("2026-09-21T12:00:00Z")
        for missing in [-14, -7, -1] {
            let summary = try NotchHistorySummary(snapshot: snapshot(now: now, missing: missing), now: now)
            try require(summary.change == nil && summary.comparisonNote == "Not enough history for a weekly percentage.",
                        "Missing days became a percentage baseline")
            try require(summary.recentSampleDays + summary.previousSampleDays == 13, "Missing sample day counted")
        }
        let gap = try NotchHistorySummary(snapshot: snapshot(now: now, gap: -10), now: now)
        try require(gap.change == nil && gap.comparisonNote == "Recording gaps; weekly percentage unavailable.",
                    "Recording gap produced a weekly percentage")
        let todayGap = try NotchHistorySummary(snapshot: snapshot(now: now, gap: 0), now: now)
        try require(todayGap.change == 100, "Today's gap affected completed weeks")
        let partialStart = calendar.addingDays(-14, to: calendar.calendar.startOfDay(for: now)).addingTimeInterval(1)
        let partial = try NotchHistorySummary(snapshot: snapshot(now: now, began: partialStart), now: now)
        try require(partial.change == nil, "Mid-day opt-in compared a partial baseline")
        let zero = try NotchHistorySummary(snapshot: snapshot(now: now, zeroBaseline: true), now: now)
        try require(zero.previous.calls == 7 && zero.previous.total == 0 && zero.change == nil,
                    "Zero observed baseline divided by zero or became missing samples")
        try require(zero.comparisonNote == "No percentage baseline (0 observed tokens).", "Zero baseline copy")
        let before = date("2026-09-21T03:59:59Z")
        let saved = try snapshot(now: before)
        let a = try NotchHistorySummary(snapshot: saved, now: before)
        let b = try NotchHistorySummary(snapshot: saved, now: before.addingTimeInterval(1))
        try require(a.today.total == 1_000 && b.today.calls == 0 && b.recent.total == 1_120 && b.previous.total == 80,
                    "Fixed-zone midnight failed to roll today into the completed week")
        try require(b.recentPeriod == "2026-09-14 - 2026-09-20" && b.previousPeriod == "2026-09-07 - 2026-09-13",
                    "Notch period labels do not match query boundaries")
    }

    static func warnings() throws {
        var policy = ContextWarningPolicy()
        let now = date("2026-09-21T12:00:00Z")
        func sample(_ value: Int64, _ offset: Double) -> Notice? {
            let date = now.addingTimeInterval(offset)
            return policy.evaluate(context(value, at: date), now: date)
        }
        try require(sample(90, 0) == nil, "Initial high sample warned")
        try require(sample(69, 1) == nil, "Low sample warned")
        let notice = sample(80, 2)
        try require(notice != nil, "Exact threshold did not warn")
        try require(sample(95, 3) == nil, "Repeated high sample warned")
        try require(sample(69, 4) == nil && sample(80, 5) == nil, "Cooldown ignored")
        try require(sample(69, 400) == nil && sample(80, 401) == nil, "Stale baseline lost cooldown")
        _ = sample(69, 602)
        try require(sample(80, 603) != nil, "Cooldown did not expire")
        var ledger = NotificationLedger()
        var preferences = NotificationPreferences()
        preferences.enabled = true
        try require(!preferences.categories.contains(.context), "Context warnings default on")
        try require(ledger.evaluate(notice!, preferences: preferences, now: now) == nil, "Disabled category delivered")
        preferences.categories.insert(.context)
        try require(ledger.evaluate(notice!, preferences: preferences, now: now) == nil, "Suppressed notice replayed")
    }

    static func storageFailures() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root)
        try require(store != nil, "Fixture store not opened")
        store = nil
        let file = root.appendingPathComponent("history/usage.sqlite")
        var db: OpaquePointer?
        try require(sqlite3_open(file.path, &db) == SQLITE_OK, "Fixture database")
        try require(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil) == SQLITE_OK, "Fixture schema")
        sqlite3_close(db)
        try rejects("Future schema overwritten") { _ = try UsageHistoryStore(root: root) }
        try UsageHistoryStore.removeArchive(root: root)
        try PrivateFiles.write(Data("invalid database".utf8), to: file)
        try rejects("Corrupt archive became empty success") { _ = try UsageHistoryStore(root: root) }
        try UsageHistoryStore.removeArchive(root: root)
        let target = root.appendingPathComponent("unrelated")
        try PrivateFiles.write(Data("untouched".utf8), to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        try rejects("Symlink followed") { _ = try UsageHistoryStore(root: root) }
        try rejects("Symlink deleted through clear") { try UsageHistoryStore.removeArchive(root: root) }
        try require(try Data(contentsOf: target) == Data("untouched".utf8), "Unrelated file changed")
    }

    static func multiYearArchive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zone = TimeZone(secondsFromGMT: 0)!
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: zone)
        try require(store != nil, "Fixture initialization")
        store = nil
        var db: OpaquePointer?
        try require(sqlite3_open(root.appendingPathComponent("history/usage.sqlite").path, &db) == SQLITE_OK, "Large archive fixture")
        let result = sqlite3_exec(db, """
        WITH RECURSIVE dates(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM dates WHERE n<3659),
          models(m) AS (SELECT 0 UNION ALL SELECT m+1 FROM models WHERE m<19)
        INSERT INTO usage(day,model,accounting,input,output,cache_input,calls,first_sum,first_count,duration_sum,duration_count)
        SELECT date('2016-01-01', '+' || n || ' days'), 'model-' || m, 1, 10, 2, 8, 1, 10, 1, 20, 1
        FROM dates CROSS JOIN models;
        """, nil, nil, nil)
        sqlite3_close(db)
        try require(result == SQLITE_OK, "Could not seed multi-year archive")
        store = try UsageHistoryStore(root: root, zone: zone)
        let now = date("2025-06-15T12:00:00Z")
        let interval = store!.clock.interval(.month, selected: now, now: now)
        let snapshot = try store!.query(interval)
        try require(snapshot.days.count == 30 && snapshot.models.count == 20, "Range query loaded excess dates")
        try require(snapshot.totals.calls == 600 && snapshot.totals.total == 12000, "Multi-year archive query sums")
        try require(snapshot.totals.meanFirstToken == 10, "Weighted latency across dates")
        store = nil
    }

    static func run() throws {
        try persistence()
        try migration()
        try contracts()
        try calendars()
        try notchSummary()
        try warnings()
        try storageFailures()
        try multiYearArchive()
    }
}
