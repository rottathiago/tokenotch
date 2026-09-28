import Foundation
import SQLite3
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum SourceHistoryChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let now = date("2020-06-10T12:00:00Z")
    static let zone = TimeZone(secondsFromGMT: 0)!

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(description: message)
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-source-history-\(UUID().uuidString)")
    }

    static func event(_ id: String, source: UsageSource = .vscodeLocal, at time: Date = now,
                      model: String? = "shared", reported: Bool? = nil, writeReported: Bool? = nil,
                      first: Double? = nil, duration: Double? = nil,
                      session: String = "private-session") -> ActivityEvent {
        ActivityEvent(source: source.client, session: ActivityEvent.digest(session), kind: .usage,
            timestamp: time,
            tokens: TokenUsage(callID: ActivityEvent.digest(id), input: 10, output: 2,
                cacheInput: reported == true ? 3 : 0, cacheInputReported: reported, model: model,
                durationMs: duration, timeToFirstTokenMs: first,
                cacheWrite: writeReported == true ? 4 : 0, cacheWriteReported: writeReported),
            metricSource: source == .cli ? nil : source)
    }

    private static func withDatabase<T>(_ root: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("history/usage.sqlite").path, &db) == SQLITE_OK,
              let db else { throw Failure(description: "Open source history fixture") }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func sql(_ root: URL, _ sql: String) throws {
        try withDatabase(root) { db in
            try require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Source history fixture SQL")
        }
    }

    private static func rows(_ root: URL, _ sql: String) throws -> [[String?]] {
        try withDatabase(root) { db in
            var statement: OpaquePointer?
            try require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Prepare fixture query")
            defer { sqlite3_finalize(statement) }
            var result: [[String?]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                try require(status == SQLITE_ROW, "Read fixture query")
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            }
        }
    }

    private static func legacy(_ root: URL, version: Int) throws {
        try PrivateFiles.directory(root)
        let directory = root.appendingPathComponent("history")
        try PrivateFiles.directory(directory)
        try PrivateFiles.write(Data(), to: directory.appendingPathComponent("usage.sqlite"))
        let cache = version >= 2 ? "cache_input INTEGER NOT NULL DEFAULT 0," : ""
        let reporting = version >= 3
            ? "cache_reported_calls INTEGER NOT NULL DEFAULT 0,cache_unreported_calls INTEGER NOT NULL DEFAULT 0," : ""
        let accounting = version >= 4 ? """
            accounting INTEGER NOT NULL DEFAULT 0,cache_write INTEGER NOT NULL DEFAULT 0,
            write_reported_calls INTEGER NOT NULL DEFAULT 0,write_unreported_calls INTEGER NOT NULL DEFAULT 0,
            """ : ""
        try sql(root, """
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT INTO metadata VALUES ('zone','GMT'),('began','\(now.addingTimeInterval(-86400).timeIntervalSince1970)'),
          ('fixture_provenance','untouched');
        CREATE TABLE usage(day TEXT NOT NULL,model TEXT NOT NULL,
          input INTEGER NOT NULL DEFAULT 0,output INTEGER NOT NULL DEFAULT 0,calls INTEGER NOT NULL DEFAULT 0,
          \(cache)\(reporting)\(accounting)
          first_sum REAL NOT NULL DEFAULT 0,first_count INTEGER NOT NULL DEFAULT 0,
          duration_sum REAL NOT NULL DEFAULT 0,duration_count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(day,model\(version >= 4 ? ",accounting" : "")));
        INSERT INTO usage(day,model,input,output,calls,first_sum,first_count,duration_sum,duration_count)
          VALUES ('2020-06-10','shared',100,20,2,4.5,1,9.25,1);
        CREATE TABLE context(day TEXT PRIMARY KEY,maximum REAL,completed INTEGER NOT NULL DEFAULT 0,
          failed INTEGER NOT NULL DEFAULT 0,seen INTEGER NOT NULL DEFAULT 0);
        INSERT INTO context VALUES ('2020-06-10',1.25,3,2,1);
        CREATE TABLE coverage(day TEXT PRIMARY KEY,seconds REAL NOT NULL DEFAULT 0,gap INTEGER NOT NULL DEFAULT 0);
        INSERT INTO coverage VALUES ('2020-06-10',12.75,1);
        CREATE TABLE receipts(id TEXT PRIMARY KEY,time REAL NOT NULL);
        CREATE INDEX receipts_time ON receipts(time);
        INSERT INTO receipts VALUES ('\(ActivityEvent.digest("legacy-receipt"))','\(now.timeIntervalSince1970)');
        PRAGMA user_version=\(version);
        """)
        if version >= 2 { try sql(root, "UPDATE usage SET cache_input=7;") }
        if version >= 3 { try sql(root, "UPDATE usage SET cache_reported_calls=1,cache_unreported_calls=1;") }
        if version >= 4 {
            try sql(root, """
            INSERT INTO usage(day,model,accounting,input,output,cache_input,cache_write,calls,
              cache_reported_calls,write_reported_calls,first_sum,first_count,duration_sum,duration_count)
              VALUES ('2020-06-10','shared',1,9,3,1,2,1,1,1,8,1,15,1);
            """)
        }
        if version == 5 {
            try sql(root, """
            INSERT INTO metadata VALUES ('hourly_began','\(now.addingTimeInterval(-3600).timeIntervalSince1970)');
            CREATE TABLE hourly_usage(start REAL PRIMARY KEY,tokens INTEGER NOT NULL DEFAULT 0,
              calls INTEGER NOT NULL DEFAULT 0,seconds REAL NOT NULL DEFAULT 0,gap INTEGER NOT NULL DEFAULT 0);
            INSERT INTO hourly_usage VALUES (\(now.timeIntervalSince1970),142,3,12.75,1);
            """)
        }
    }

    static func migration() throws {
        for version in 1...5 {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            try legacy(root, version: version)
            let names = try rows(root, "PRAGMA table_info(usage)").compactMap { $0[1] }
            let columns = names.joined(separator: ",")
            let previous = try rows(root, "SELECT \(columns) FROM usage ORDER BY day,model")
            var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: TimeZone(identifier: "Asia/Tokyo")!, now: now)
            let interval = store!.clock.interval(.today, selected: now, now: now)
            let all = try store!.query(interval), cli = try store!.query(interval, source: .cli)
            try require(all.totals == cli.totals && all.models.count == 1, "Migration source/model grouping")
            try require(all.totals.input == (version >= 4 ? 109 : 100)
                && all.totals.output == (version >= 4 ? 23 : 20)
                && all.totals.calls == (version >= 4 ? 3 : 2)
                && all.totals.cacheInput == (version >= 4 ? 8 : version >= 2 ? 7 : 0)
                && all.totals.cacheWrite == (version >= 4 ? 2 : 0)
                && all.totals.unverifiedCalls == 2, "Legacy counts/accounting changed")
            try require(all.totals.cacheReportedCalls == (version >= 4 ? 2 : version >= 3 ? 1 : 0)
                && all.totals.cacheUnreportedCalls == (version >= 3 ? 1 : 0)
                && all.totals.cacheWriteReportedCalls == (version >= 4 ? 1 : 0)
                && all.totals.cacheWriteUnreportedCalls == 0, "Legacy optional counters changed")
            try require(all.days.first?.contextMaximum == 1.25 && all.days.first?.compactions == 3
                && all.days.first?.failedCompactions == 2 && all.days.first?.hasCompaction == true
                && all.days.first?.recordingSeconds == 12.75 && all.days.first?.gap == true,
                "Legacy context/coverage changed")
            try require(all.zone == zone.identifier && all.began == now.addingTimeInterval(-86400)
                && store!.hourlyBegan == (version == 5 ? now.addingTimeInterval(-3600) : now)
                && !all.hasImportedData, "Migration invented collection or import provenance")
            try require(try rows(root, "SELECT \(columns) FROM usage ORDER BY day,model") == previous,
                        "Migration changed an existing usage field")
            try require(try rows(root, "SELECT DISTINCT source FROM usage") == [["cli"]], "Legacy rows not explicit CLI")
            try require(try rows(root, "SELECT value FROM metadata WHERE key='fixture_provenance'") == [["untouched"]],
                        "Unrelated metadata changed")
            try require(try rows(root, "PRAGMA user_version") == [["6"]], "Schema did not reach six")
            for source in [UsageSource.vscodeLocal, .vscodeCopilot] {
                let empty = try store!.query(interval, source: source)
                try require(empty.totals.calls == 0 && empty.days.isEmpty && empty.models.isEmpty,
                            "Legacy rows attributed to VS Code")
            }
            let hourly = try store!.hourlyTimeline(now: now)
            try require(hourly.total == (version == 5 ? 142 : 0)
                && hourly.calls == (version == 5 ? 3 : 0), "Hourly migration changed or manufactured observations")
            if version == 5 {
                try require(try rows(root, "SELECT start,tokens,calls,seconds,gap FROM hourly_usage WHERE source='cli'")
                    == [[String(now.timeIntervalSince1970), "142", "3", "12.75", "1"]], "Hourly fields changed")
            }
            try require(try store!.record([event("legacy-receipt", source: .cli)], now: now) == 0,
                        "Migration lost existing CLI receipts")
            let fresh = event("fresh", source: .vscodeLocal, reported: true, writeReported: true)
            try require(try store!.record([fresh], now: now) == 1, "Post-migration VS Code insertion failed")
            let combined = try store!.query(interval)
            try require(combined.models.count == 1 && combined.models[0].tokens == combined.totals,
                        "Mixed accounting/source model rows did not combine")
            store = nil
            store = try UsageHistoryStore(root: root, now: now)
            try require(try store!.query(interval).totals == combined.totals, "Migration changed on reopen")
            try require(try store!.record([fresh], now: now) == 0, "Reopen lost durable migration-era receipt")
        }
    }

    private static func requireSum(_ total: HistoryTotals, _ parts: [HistoryTotals]) throws {
        let integers: [KeyPath<HistoryTotals, Int64>] = [
            \.input, \.output, \.cacheInput, \.cacheWrite, \.calls, \.total, \.unverifiedCalls,
            \.cacheReportedCalls, \.cacheUnreportedCalls, \.cacheWriteReportedCalls, \.cacheWriteUnreportedCalls,
            \.firstTokenSamples, \.durationSamples
        ]
        for key in integers {
            try require(total[keyPath: key] == parts.reduce(0) { $0 + $1[keyPath: key] }, "Source totals do not reconcile")
        }
        try require(total.firstTokenSum == parts.reduce(0) { $0 + $1.firstTokenSum }
            && total.durationSum == parts.reduce(0) { $0 + $1.durationSum }, "Source latency sums do not reconcile")
    }

    static func sourceTotals() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, zone: zone, now: now)
        for source in UsageSource.allCases {
            try store.record([
                event("shared-\(source.rawValue)", source: source, reported: true, writeReported: true, first: 10, duration: 20),
                event("absent-\(source.rawValue)", source: source, model: "other", reported: false, writeReported: false),
                event("unknown-\(source.rawValue)", source: source, model: nil)
            ], now: now)
        }
        let interval = store.clock.interval(.today, selected: now, now: now)
        let all = try store.query(interval)
        let parts = try UsageSource.allCases.map { try store.query(interval, source: $0) }
        try requireSum(all.totals, parts.map(\.totals))
        try require(all.totals.calls == 9 && all.models.count == 3
            && all.totals.cacheCoverage.unknownCalls == 3 && all.totals.cacheUnreportedCalls == 3
            && all.totals.breakdown.write.unknownCalls == 3 && all.totals.cacheWriteUnreportedCalls == 3
            && all.totals.firstTokenSamples == 3 && all.totals.durationSamples == 3,
            "Missing optional counters became reported zeros")
        for model in all.models {
            try requireSum(model.tokens, parts.flatMap(\.models).filter { $0.id == model.id }.map(\.tokens))
            for source in UsageSource.allCases {
                let filtered = try store.query(interval, model: model.id, source: source)
                try require(filtered.totals == filtered.models.first { $0.id == model.id }?.tokens,
                            "Combined model/source filter failed")
            }
        }
        let hourly = try store.hourlyTimeline(now: now)
        let hourlyParts = try UsageSource.allCases.map { try store.hourlyTimeline(now: now, source: $0) }
        try require(hourly.total == all.totals.total && hourly.calls == all.totals.calls, "Hourly/daily source sums differ")
        for index in hourly.buckets.indices {
            try require(hourly.buckets[index].tokens == hourlyParts.reduce(0) { $0 + $1.buckets[index].tokens }
                && hourly.buckets[index].calls == hourlyParts.reduce(0) { $0 + $1.buckets[index].calls },
                "All-source hourly buckets differ from source sums")
        }
        for index in 0..<105 {
            try store.record([event("bounded-\(index)", source: UsageSource.allCases[index % 3], model: "model-\(index)")], now: now)
        }
        let bounded = try store.query(interval)
        try require(bounded.models.count == 101 && bounded.models.contains { $0.id == "*" }
            && bounded.totals.calls == 114, "Model cap was per-source or discarded counts")
        try require(try rows(root, "SELECT count(DISTINCT model) FROM usage WHERE model!='*'") == [["100"]],
                    "Global daily model-detail bound changed")
    }

    static func durableReceipts() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: zone, now: now)
        let local = event("canonical"), copilot = event("canonical", source: .vscodeCopilot)
        try require(try store!.countNew([local, local, copilot]) == 2, "Preview did not canonicalize within input")
        try require(try store!.record([local, local], now: now) == 1, "Live durable insertion count")
        try require(try store!.countNew([local, copilot, copilot]) == 1, "Preview ignored stored/live receipts")
        try require(try store!.record([copilot, copilot], now: now, importing: true) == 1, "Import insertion count")
        let later = now.addingTimeInterval(601)
        try require(try store!.record([local, copilot], now: later) == 0, "Durable live receipts expired at ten minutes")
        let canonical = event("canonical", at: later, session: "different-live-envelope")
        try require(try store!.record([canonical], now: later, importing: true) == 0,
                    "Timestamp/session envelope changed canonical receipt")
        try store!.heartbeat(from: later, to: later, active: false, sources: Set(UsageSource.allCases))
        let key = try rows(root, "SELECT value FROM metadata WHERE key='receipt_key'")
        let receipts = try rows(root, "SELECT id FROM durable_receipts ORDER BY id")
        let bytes = try Data(contentsOf: root.appendingPathComponent("history/usage.sqlite"))
        let contents = String(decoding: bytes, as: UTF8.self)
        try require(!contents.contains(local.session) && !contents.contains(local.tokens!.callID)
            && !contents.contains("private-session") && receipts.count == 2
            && receipts.allSatisfy { $0[0]?.count == 64 }, "Receipt retained unkeyed identifiers")
        store = nil
        let expired = now.addingTimeInterval(20 * 86400)
        store = try UsageHistoryStore(root: root, now: expired)
        try require(try store!.countNew([local, copilot]) == 0, "Reopen lost durable receipts")
        try require(try store!.record([local, copilot], now: expired, importing: true) == 0,
                    "Reimport after hourly expiry double counted")
        try require(try rows(root, "SELECT id FROM durable_receipts ORDER BY id") == receipts
            && rows(root, "SELECT value FROM metadata WHERE key='receipt_key'") == key,
            "Durable receipt/key changed after reopen")
        try require(try rows(root, "SELECT sum(calls) FROM hourly_usage") == [["0"]]
            && rows(root, "SELECT count(*) FROM hourly_usage WHERE start<\(expired.addingTimeInterval(-7 * 86400).timeIntervalSince1970)") == [["0"]],
            "Expired hourly detail retained")
        let saved = try store!.query(store!.clock.interval(.day, selected: now, now: now))
        try require(saved.totals.calls == 2 && saved.hasImportedData, "Daily totals/import provenance pruned with hourly detail")
        try store!.delete()
        store = nil
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/usage.sqlite").path),
                    "Delete left import metadata")
        store = try UsageHistoryStore(root: root, zone: zone, now: expired)
        try require(try store!.countNew([local, copilot]) == 2, "Delete retained durable receipts")
        try require(try rows(root, "SELECT value FROM metadata WHERE key='receipt_key'") != key, "Delete reused receipt key")
        try require(try store!.record([event("cli", source: .cli)], now: expired) == 1, "CLI insertion failed")
        try store!.heartbeat(from: expired, to: expired, active: false, sources: [.vscodeLocal])
        try require(try store!.record([event("cli", source: .cli)], now: expired) == 0, "VS Code pause cleared CLI receipts")
        try store!.heartbeat(from: expired, to: expired, active: false)
        try require(try store!.record([event("cli", source: .cli)], now: expired) == 1, "CLI pause no longer clears short receipts")
        try require(try store!.record([event("cli", source: .cli)], now: expired.addingTimeInterval(601)) == 1,
                    "CLI receipts became permanent")
    }

    static func importsAndRollback() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, zone: zone, now: now)
        let cutoff = store.clock.interval(.week, selected: now, now: now).start
        let samples = [
            event("ancient", at: date("2000-01-01T12:00:00Z")),
            event("outside", at: cutoff.addingTimeInterval(-0.001)),
            event("boundary", at: cutoff),
            event("recent", source: .vscodeCopilot, at: now.addingTimeInterval(-86400))
        ]
        try require(try store.record(samples, now: now, importing: true) == 4, "Past daily import rejected")
        try require(try rows(root, "SELECT sum(calls) FROM hourly_usage") == [["2"]], "Seven-reporting-day import cutoff")
        try require(try rows(root, "SELECT sum(calls) FROM usage") == [["4"]], "Daily import retention was limited")
        for sample in samples {
            let interval = store.clock.interval(.day, selected: sample.timestamp, now: now)
            let saved = try store.query(interval, source: sample.usageSource)
            try require(saved.totals.calls == 1 && saved.hasImportedData && saved.days.first?.imported == true
                && saved.days.first?.gap == true && saved.days.first?.recordingSeconds == 0,
                "Import manufactured coverage or lost partial/provenance flag")
            try require(saved.began == now && store.hourlyBegan == now, "Import backdated collection start")
        }
        let hourly = try store.hourlyTimeline(now: cutoff)
        try require(hourly.calls == 1 && hourly.buckets[0].gap
            && hourly.buckets[0].recordingSeconds == 0
            && hourly.buckets[0].coverage(at: now) == .partial, "Pre-hourly-began import not visible as partial")
        let cli = try store.query(store.clock.interval(.week, selected: now, now: now), source: .cli)
        try require(!cli.hasImportedData && cli.totals.calls == 0 && cli.days.isEmpty, "Import contaminated CLI")
        try rejects("CLI import accepted") { _ = try store.record([event("cli", source: .cli)], now: now, importing: true) }
        try rejects("CLI import preview accepted") { _ = try store.countNew([event("cli", source: .cli)]) }
        try rejects("Future import accepted") {
            _ = try store.record([event("future", at: now.addingTimeInterval(1))], now: now, importing: true)
        }
        try rejects("Future live history accepted") {
            _ = try store.record([event("future", at: now.addingTimeInterval(31))], now: now)
        }
        try rejects("Future import preview accepted") {
            _ = try store.countNew([event("future-preview", at: Date().addingTimeInterval(60))])
        }
        try rejects("Nonfinite timestamp accepted") {
            _ = try store.record([event("invalid", at: Date(timeIntervalSince1970: .infinity))], now: now, importing: true)
        }
        let valid = event("retry", at: now)
        try rejects("Invalid tail committed partial import") {
            _ = try store.record([valid, event("invalid-latency", first: .nan)], now: now, importing: true)
        }
        try require(try store.countNew([valid]) == 1, "Failed transaction retained receipt")
        try sql(root, "CREATE TRIGGER fail_hourly BEFORE INSERT ON hourly_usage BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        try rejects("Hourly failure committed daily import") { _ = try store.record([valid], now: now, importing: true) }
        try require(try rows(root, "SELECT sum(calls) FROM usage") == [["4"]] && store.countNew([valid]) == 1,
                    "Failed hourly write changed daily totals/receipts")
        try sql(root, "DROP TRIGGER fail_hourly;")
        try require(try store.record([valid], now: now, importing: true) == 1, "Failed receipt suppressed retry")
        try require(try store.record([valid], now: now.addingTimeInterval(601)) == 0,
                    "Live delivery after import was counted again")
        try store.heartbeat(from: now, to: now.addingTimeInterval(60), active: true, sources: [.vscodeLocal])
        let covered = try store.hourlyTimeline(now: now.addingTimeInterval(60), source: .vscodeLocal)
        try require(covered.buckets[12].recordingSeconds == 60
            && covered.buckets[12].coverage(at: now.addingTimeInterval(60)) == .partial,
            "Full live coverage erased imported partial provenance")

        for offset in 1...8 {
            let date = store.clock.addingDays(offset, to: now)
            try store.record([event("retained-\(offset)", source: .vscodeCopilot, at: date)], now: date)
        }
        try require(try rows(root, "SELECT count(DISTINCT start) FROM hourly_usage") == [["7"]]
            && rows(root, "SELECT sum(calls) FROM usage") == [["13"]],
            "Rolling retention lost daily totals or retained old hourly detail")
        try require(try store.countNew(samples + [valid]) == 0, "Hourly pruning discarded durable import receipts")
    }

    static func coverageUnion() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: zone, now: now)
        let day = store!.clock.interval(.today, selected: now, now: now)
        func beat(_ start: Double, _ end: Double, _ sources: Set<UsageSource>) throws {
            try store!.heartbeat(from: now.addingTimeInterval(start), to: now.addingTimeInterval(end),
                                 active: true, sources: sources)
        }
        func seconds(_ source: UsageSource? = nil) throws -> Double {
            try store!.query(day, source: source).days.first?.recordingSeconds ?? 0
        }
        try beat(0, 30, [.cli])
        try beat(30, 60, [.vscodeLocal])
        try require(try seconds() == 60, "Non-overlapping sources reduced to maximum instead of union")
        try beat(15, 45, [.vscodeLocal])
        try beat(20, 40, [.vscodeCopilot])
        try beat(0, 30, [.cli])
        try require(try seconds() == 60 && seconds(.cli) == 30 && seconds(.vscodeLocal) == 45
            && seconds(.vscodeCopilot) == 20, "Overlapping/replayed coverage double counted")
        try beat(60, 90, [.cli])
        try beat(120, 150, [.vscodeCopilot])
        try require(try seconds() == 120, "Disjoint union filled an unobserved hole")
        store = nil
        store = try UsageHistoryStore(root: root, zone: zone, now: now.addingTimeInterval(150))
        try beat(90, 120, [.vscodeLocal])
        try beat(151.25, 152.75, [.cli, .vscodeLocal])
        try beat(152, 153.25, [.vscodeCopilot])
        try require(try seconds() == 152 && seconds(.cli) == 61.5 && seconds(.vscodeLocal) == 76.5
            && seconds(.vscodeCopilot) == 51.25, "Restart/fractional union lost checkpoint positions")
        let hourly = try store!.hourlyTimeline(now: now.addingTimeInterval(154))
        try require(hourly.buckets[12].recordingSeconds == 152, "Hourly union disagrees with daily union")
        try beat(3600, 3630, Set(UsageSource.allCases))
        try require(try seconds() == 182, "Simultaneous opportunity counted once per source")
        let midnight = store!.clock.addingDays(1, to: day.start)
        try store!.heartbeat(from: midnight.addingTimeInterval(-10), to: midnight.addingTimeInterval(20),
                             active: true, sources: [.cli, .vscodeLocal])
        try require(try seconds() == 192, "Union not split at reporting midnight")
        let next = try store!.hourlyTimeline(now: midnight.addingTimeInterval(20))
        try require(next.buckets[0].recordingSeconds == 20, "Hourly union not split at midnight")
        try store!.markGap(at: midnight, sources: [.vscodeCopilot])
        try require(try store!.hourlyTimeline(now: midnight, source: .vscodeCopilot).buckets[0].gap
            && !store!.hourlyTimeline(now: midnight, source: .cli).buckets[0].gap
            && store!.hourlyTimeline(now: midnight).buckets[0].gap, "Source-specific gap leaked or disappeared")

        let before = try rows(root, "SELECT * FROM coverage ORDER BY day,source")
        try sql(root, """
        CREATE TRIGGER fail_coverage BEFORE INSERT ON coverage
          WHEN NEW.source='vscodeLocal' BEGIN SELECT RAISE(ABORT,'fixture'); END;
        """)
        try rejects("Heartbeat failure committed a partial union") { try beat(200, 230, [.cli, .vscodeLocal]) }
        try require(try rows(root, "SELECT * FROM coverage ORDER BY day,source") == before, "Heartbeat rollback changed coverage")
        try sql(root, "DROP TRIGGER fail_coverage;")
        try beat(200, 230, [.cli, .vscodeLocal])
        try require(try seconds() == 222, "Rolled-back checkpoint suppressed retry")
        try beat(400, 500, [.vscodeLocal])
        try beat(600, 550, [.cli])
        try require(try seconds() == 222, "Sleep or clock rollback manufactured coverage")
        try beat(700, 730, [])
        try require(try seconds() == 222, "Empty source heartbeat invented opportunity")
    }

    static func schemaRollback() throws {
        for version in [1, 3, 5] {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            try legacy(root, version: version)
            try sql(root, "UPDATE metadata SET value='not-a-zone' WHERE key='zone';")
            let before = try rows(root, "SELECT sql FROM sqlite_master ORDER BY name")
            let data = try rows(root, "SELECT * FROM usage ORDER BY day,model")
            try rejects("Corrupt migration succeeded") { _ = try UsageHistoryStore(root: root, now: now) }
            try require(try rows(root, "PRAGMA user_version") == [[String(version)]]
                && rows(root, "SELECT sql FROM sqlite_master ORDER BY name") == before
                && rows(root, "SELECT * FROM usage ORDER BY day,model") == data,
                "Failed multi-stage migration did not roll back schema and data")
        }
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try legacy(root, version: 5)
        try sql(root, "UPDATE usage SET input=-1;")
        try rejects("Corrupt numeric migration accepted") { _ = try UsageHistoryStore(root: root, now: now) }
        try require(try rows(root, "PRAGMA user_version") == [["5"]]
            && rows(root, "SELECT DISTINCT input FROM usage") == [["-1"]], "Corrupt migration altered original rows")
        try sql(root, "PRAGMA user_version=999;")
        let file = root.appendingPathComponent("history/usage.sqlite")
        let before = try Data(contentsOf: file)
        try rejects("Unknown schema accepted") { _ = try UsageHistoryStore(root: root, now: now) }
        try require(try Data(contentsOf: file) == before, "Unknown schema database changed")
        try UsageHistoryStore.removeArchive(root: root)
        let corrupt = Data("not a SQLite database".utf8)
        try PrivateFiles.write(corrupt, to: file)
        try rejects("Corrupt database reset") { _ = try UsageHistoryStore(root: root, now: now) }
        try require(try Data(contentsOf: file) == corrupt, "Corrupt database modified")
    }

    static func legacyCoverageCap() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try legacy(root, version: 5)
        try sql(root, "UPDATE coverage SET seconds=86390; UPDATE hourly_usage SET seconds=3590;")
        let store = try UsageHistoryStore(root: root, zone: zone, now: now)
        let interval = store.clock.interval(.today, selected: now, now: now)
        try require(try store.query(interval).days.first?.recordingSeconds == 86390,
                    "Migration capped original legacy coverage")
        try store.heartbeat(from: now, to: now.addingTimeInterval(60), active: true, sources: [.vscodeLocal])
        try require(try store.query(interval).days.first?.recordingSeconds == 86400
            && store.query(interval, source: .cli).days.first?.recordingSeconds == 86390
            && store.query(interval, source: .vscodeLocal).days.first?.recordingSeconds == 60,
            "Legacy baseline plus new union exceeded daily opportunity")
        try require(try store.hourlyTimeline(now: now.addingTimeInterval(60)).buckets[12].recordingSeconds == 3600
            && store.hourlyTimeline(now: now, source: .cli).buckets[12].recordingSeconds == 3590,
            "Legacy baseline plus new union exceeded hourly opportunity")
    }

    static func run() throws {
        try migration()
        try sourceTotals()
        try durableReceipts()
        try importsAndRollback()
        try coverageUnion()
        try legacyCoverageCap()
        try schemaRollback()
        print("PASS: source history migration, source sums, durable receipts, import retention/provenance, coverage union and rollback")
    }
}
