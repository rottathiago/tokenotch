import Foundation
import SQLite3
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum UsageTimelineChecks {
    static func calendars() throws {
        for (zone, day, count, duration) in [
            ("America/New_York", "2026-03-08T12:00:00Z", 23, 23.0),
            ("America/New_York", "2026-11-01T12:00:00Z", 25, 25.0),
            ("Asia/Kathmandu", "2026-09-24T12:00:00Z", 24, 24.0),
            ("Australia/Lord_Howe", "2026-10-04T12:00:00Z", 24, 23.5),
            ("Australia/Lord_Howe", "2026-04-05T12:00:00Z", 25, 24.5)
        ] {
            let clock = HistoryCalendar(zone: TimeZone(identifier: zone)!)
            let now = HistoryChecks.date(day)
            let hours = clock.hours(on: now)
            let interval = clock.interval(.today, selected: now, now: now)
            try HistoryChecks.require(hours.count == count, "\(zone) hour count: \(hours.count), expected \(count)")
            try HistoryChecks.require(Set(hours.map(\.start)).count == hours.count, "Repeated local hours collided")
            try HistoryChecks.require(hours.first?.start == interval.start && hours.last?.end == interval.end,
                                      "Hourly buckets do not cover the day")
            try HistoryChecks.require(hours.reduce(0) { $0 + $1.duration } == duration * 3600, "DST duration lost")
            for (index, hour) in hours.enumerated() {
                if index > 0 { try HistoryChecks.require(hours[index - 1].end == hour.start, "Hourly gap/overlap") }
                try HistoryChecks.require(clock.hour(containing: hour.start.addingTimeInterval(1)).start == hour.start,
                                          "\(zone): storage bucketing differs at \(hour.start)")
            }
            let root = HistoryChecks.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try UsageHistoryStore(root: root, zone: clock.calendar.timeZone, now: interval.start)
            for (index, hour) in hours.enumerated() {
                let date = hour.start.addingTimeInterval(1)
                try store.record([HistoryChecks.usage("hour-\(index)", at: date)], now: date)
            }
            let saved = try store.hourlyTimeline(now: interval.end.addingTimeInterval(-1))
            try HistoryChecks.require(saved.calls == Int64(count) && saved.buckets.allSatisfy { $0.calls == 1 },
                                      "Saved DST intervals merged or lost calls")
        }
    }

    static func live() throws {
        var clock = HistoryCalendar(zone: TimeZone(identifier: "America/New_York")!)
        let now = HistoryChecks.date("2026-11-01T06:01:00Z")
        let before = HistoryChecks.date("2026-11-01T05:59:00Z")
        var ledger = TokenLedger()
        let first = HistoryChecks.usage("before", at: before, cacheInput: 7)
        try ledger.observe(first, now: before)
        try ledger.observe(first, now: before)
        try ledger.observe(HistoryChecks.usage("after", at: now), now: now)
        let timeline = ledger.hourlyTimeline(now: now, calendar: clock.calendar)
        try HistoryChecks.require(timeline.buckets.count == 25 && timeline.calls == 2 && timeline.total == 31,
                                  "Live totals/deduplication or fall-back buckets")
        try HistoryChecks.require(timeline.buckets.filter { $0.calls > 0 }.count == 2, "Repeated hour merged")
        try HistoryChecks.require(timeline.total == ledger.today(now: now, calendar: clock.calendar)?.total,
                                  "Live chart disagrees with Today's tokens")
        try HistoryChecks.require(timeline.buckets.filter { $0.calls > 0 }.allSatisfy { $0.coverage(at: now) == .partial },
                                  "Live samples invented complete recording coverage")
        let future = now.addingTimeInterval(20)
        try ledger.observe(HistoryChecks.usage("future", at: future), now: now)
        try HistoryChecks.require(ledger.hourlyTimeline(now: now, calendar: clock.calendar).calls == 2, "Future call leaked")
        try HistoryChecks.require(ledger.hourlyTimeline(now: future, calendar: clock.calendar).calls == 3,
                                  "Cached chart did not admit a now-current call")
        try HistoryChecks.require(ledger.hourlyTimeline(now: before, calendar: clock.calendar).calls == 1,
                                  "Clock rollback left a stale cache")
        clock = HistoryCalendar(zone: TimeZone(identifier: "America/Los_Angeles")!)
        try HistoryChecks.require(ledger.hourlyTimeline(now: now, calendar: clock.calendar).zone == clock.calendar.timeZone.identifier,
                                  "Live timezone change left a stale chart")
        ledger.expire(now: now.addingTimeInterval(86_430))
        try HistoryChecks.require(ledger.hourlyTimeline(now: now.addingTimeInterval(86_430)).calls == 0, "Expired hourly samples")

        ledger = TokenLedger()
        for index in 0..<4097 {
            let date = now.addingTimeInterval(Double(index) / 100)
            try ledger.observe(HistoryChecks.usage("cap-\(index)", at: date), now: date)
        }
        let capped = ledger.hourlyTimeline(now: now.addingTimeInterval(50))
        try HistoryChecks.require(capped.calls == 4096 && capped.total == ledger.today(now: now.addingTimeInterval(50))?.total
                                  && ledger.lastDiscardedAt != nil, "Chart bypassed the live sample cap")
        ledger = TokenLedger()
        try HistoryChecks.require(ledger.hourlyTimeline(now: now).total == 0, "Clear/restart retained live buckets")
    }

    static func storage() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = HistoryChecks.date("2026-09-24T00:00:00Z")
        let now = start.addingTimeInterval(3600)
        let clock = HistoryCalendar(zone: TimeZone(secondsFromGMT: 0)!)
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: clock.calendar.timeZone, now: start)
        let event = HistoryChecks.usage("boundary", at: now, cacheInput: 7)
        try store!.record([HistoryChecks.usage("first", at: start)], now: start)
        for offset in stride(from: 0, to: 3600, by: 30) {
            try store!.heartbeat(from: start.addingTimeInterval(Double(offset)),
                                 to: start.addingTimeInterval(Double(offset + 30)), active: true)
        }
        try store!.record([event, event], now: now)
        let hourly = try store!.hourlyTimeline(now: now)
        let saved = try store!.query(clock.interval(.today, selected: now, now: now))
        try HistoryChecks.require(hourly.calls == 2 && hourly.total == saved.totals.total, "Saved hourly accounting/deduplication")
        try HistoryChecks.require(hourly.buckets[0].calls == 1 && hourly.buckets[1].calls == 1, "Exact hour boundary")
        try HistoryChecks.require(hourly.buckets[0].coverage(at: now) == .recorded
                                  && hourly.buckets[1].coverage(at: now) == .partial
                                  && hourly.buckets[2].coverage(at: now) == .future, "Recording/future coverage states")
        store = nil
        store = try UsageHistoryStore(root: root, zone: TimeZone(identifier: "Asia/Tokyo")!, now: now.addingTimeInterval(1))
        try store!.record([event], now: now.addingTimeInterval(1))
        let restarted = try store!.hourlyTimeline(now: now.addingTimeInterval(1))
        try HistoryChecks.require(restarted.calls == 2 && restarted.zone == clock.calendar.timeZone.identifier,
                                  "Hourly restart lost fixed zone or deduplication")
        try HistoryChecks.require(restarted.buckets[1].gap, "Unclean restart hid hourly interruption")
        try store!.heartbeat(from: now.addingTimeInterval(1), to: now.addingTimeInterval(10), active: false)
        try store!.heartbeat(from: now.addingTimeInterval(100), to: now.addingTimeInterval(130), active: true)
        try HistoryChecks.require(try store!.hourlyTimeline(now: now.addingTimeInterval(130)).buckets[1].gap,
                                  "Pause/resume concealed hourly gap")
        let midnight = clock.addingDays(1, to: start)
        try store!.record([HistoryChecks.usage("clock-skew", at: midnight.addingTimeInterval(10))],
                          now: midnight.addingTimeInterval(-10))
        try HistoryChecks.require(try store!.hourlyTimeline(now: midnight.addingTimeInterval(10)).calls == 1,
                                  "Retention discarded an admitted slightly-future call across midnight")
        try store!.delete()
        store = nil
        store = try UsageHistoryStore(root: root, zone: clock.calendar.timeZone, now: now)
        try HistoryChecks.require(try store!.hourlyTimeline(now: now).calls == 0, "Delete retained hourly usage")
    }

    static func migrationAndRetention() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = HistoryChecks.date("2026-09-24T00:00:00Z")
        let now = start.addingTimeInterval(12 * 3600)
        let zone = TimeZone(secondsFromGMT: 0)!
        try PrivateFiles.directory(root)
        try PrivateFiles.directory(root.appendingPathComponent("history"))
        try PrivateFiles.write(Data(), to: root.appendingPathComponent("history/usage.sqlite"))
        try sql(root, """
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT INTO metadata VALUES ('zone','\(zone.identifier)'),('began','\(start.timeIntervalSince1970)');
        CREATE TABLE usage(day TEXT NOT NULL,model TEXT NOT NULL,accounting INTEGER NOT NULL,
          input INTEGER NOT NULL DEFAULT 0,output INTEGER NOT NULL DEFAULT 0,cache_input INTEGER NOT NULL DEFAULT 0,
          calls INTEGER NOT NULL DEFAULT 0,cache_reported_calls INTEGER NOT NULL DEFAULT 0,
          cache_unreported_calls INTEGER NOT NULL DEFAULT 0,cache_write INTEGER NOT NULL DEFAULT 0,
          write_reported_calls INTEGER NOT NULL DEFAULT 0,write_unreported_calls INTEGER NOT NULL DEFAULT 0,
          first_sum REAL NOT NULL DEFAULT 0,first_count INTEGER NOT NULL DEFAULT 0,
          duration_sum REAL NOT NULL DEFAULT 0,duration_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(day,model,accounting));
        INSERT INTO usage(day,model,accounting,input,output,calls) VALUES ('2026-09-24','',1,10,2,1);
        CREATE TABLE context(day TEXT PRIMARY KEY,maximum REAL,completed INTEGER NOT NULL DEFAULT 0,
          failed INTEGER NOT NULL DEFAULT 0,seen INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE coverage(day TEXT PRIMARY KEY,seconds REAL NOT NULL DEFAULT 0,gap INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE receipts(id TEXT PRIMARY KEY,time REAL NOT NULL);
        CREATE INDEX receipts_time ON receipts(time);
        PRAGMA user_version=4;
        """)
        let store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: zone, now: now)
        var timeline = try store!.hourlyTimeline(now: now)
        try HistoryChecks.require(timeline.total == 0 && timeline.detailBegan == now, "Migration fabricated hourly history")
        try HistoryChecks.require(try store!.query(store!.clock.interval(.today, selected: now, now: now)).totals.calls == 1,
                                  "Hourly migration changed daily totals")
        try store!.record([HistoryChecks.usage("new-hourly", at: now)], now: now)
        timeline = try store!.hourlyTimeline(now: now)
        try HistoryChecks.require(timeline.calls == 1, "Post-migration detail missing")
        try HistoryChecks.require(timeline.buckets[0].coverage(at: now) == .unavailable, "Pre-migration hour became zero")

        try sql(root, "CREATE TRIGGER fail_hourly BEFORE INSERT ON hourly_usage BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        let retry = HistoryChecks.usage("retry", at: now)
        try HistoryChecks.rejects("Hourly failure accepted a partial transaction") { try store!.record([retry], now: now) }
        try HistoryChecks.require(try store!.query(store!.clock.interval(.today, selected: now, now: now)).totals.calls == 2,
                                  "Hourly failure committed daily counts")
        try sql(root, "DROP TRIGGER fail_hourly;")
        try store!.record([retry], now: now)
        try HistoryChecks.require(try store!.hourlyTimeline(now: now).calls == 2, "Rolled-back receipt suppressed retry")

        for offset in 1...8 {
            let date = store!.clock.addingDays(offset, to: now)
            try store!.record([HistoryChecks.usage("day-\(offset)", at: date)], now: date)
        }
        try HistoryChecks.require(try scalar(root, "SELECT count(*) FROM hourly_usage") == 7, "Hourly retention exceeded seven days")
        let end = store!.clock.addingDays(9, to: start)
        let saved = try store!.query(DateInterval(start: start, end: end))
        try HistoryChecks.require(saved.totals.calls == 11, "Hourly pruning erased daily totals")
        let later = store!.clock.addingDays(20, to: now)
        _ = try store!.hourlyTimeline(now: later)
        try HistoryChecks.require(try scalar(root, "SELECT count(*) FROM hourly_usage") == 0, "Paused archive did not prune before display")
    }

    static func coverageAndWeek() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = HistoryChecks.date("2026-09-24T00:00:00Z")
        let now = start.addingTimeInterval(2 * 3600)
        let clock = HistoryCalendar(zone: TimeZone(secondsFromGMT: 0)!)
        let store = try UsageHistoryStore(root: root, zone: clock.calendar.timeZone, now: start)
        for offset in stride(from: 0, to: 3600, by: 30) {
            try store.heartbeat(from: start.addingTimeInterval(Double(offset)),
                                to: start.addingTimeInterval(Double(offset + 30)), active: true)
        }
        try store.heartbeat(from: start.addingTimeInterval(3600), to: start.addingTimeInterval(3630), active: true)
        let timeline = try store.hourlyTimeline(now: now)
        try HistoryChecks.require(timeline.buckets[0].tokens == 0 && timeline.buckets[0].coverage(at: now) == .recorded,
                                  "Observed zero was not distinguishable")
        try HistoryChecks.require(timeline.buckets[1].coverage(at: now) == .partial
                                  && timeline.buckets[2].coverage(at: now) == .unavailable, "Partial and unknown conflated")
        try store.record([HistoryChecks.usage("week", at: now)], now: now)
        let saved = try store.query(clock.interval(.week, selected: now, now: now))
        let week = try UsageTimeline.week(snapshot: saved, now: now)
        try HistoryChecks.require(week.buckets.count == 7 && week.total == saved.totals.total
                                  && week.calls == saved.totals.calls, "Seven-day bars do not reconcile")
        try HistoryChecks.require(week.buckets[0].coverage(at: now) == .unavailable
                                  && week.buckets[6].isCurrent(at: now), "Missing days or Today incorrectly marked")
        let boundary = start.addingTimeInterval(7190)
        try store.heartbeat(from: boundary, to: boundary.addingTimeInterval(30), active: true)
        let split = try store.hourlyTimeline(now: now)
        try HistoryChecks.require(split.buckets[1].recordingSeconds == 40 && split.buckets[2].recordingSeconds == 20,
                                  "Coverage was not split at an hour boundary")
    }

    private static func sql(_ root: URL, _ sql: String) throws {
        var db: OpaquePointer?
        try HistoryChecks.require(sqlite3_open(root.appendingPathComponent("history/usage.sqlite").path, &db) == SQLITE_OK,
                                  "Open hourly fixture")
        defer { sqlite3_close(db) }
        try HistoryChecks.require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Hourly fixture SQL failed")
    }

    private static func scalar(_ root: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        try HistoryChecks.require(sqlite3_open(root.appendingPathComponent("history/usage.sqlite").path, &db) == SQLITE_OK,
                                  "Open hourly count fixture")
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try HistoryChecks.require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Prepare hourly count")
        defer { sqlite3_finalize(statement) }
        try HistoryChecks.require(sqlite3_step(statement) == SQLITE_ROW, "Read hourly count")
        return sqlite3_column_int64(statement, 0)
    }

    static func run() throws {
        try calendars()
        try live()
        try storage()
        try migrationAndRetention()
        try coverageAndWeek()
    }
}
