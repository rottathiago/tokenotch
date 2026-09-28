import Foundation
import SQLite3
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum CacheInputChecks {
    static let now = HistoryChecks.date("2026-09-21T12:00:00Z")

    static func event(_ id: String, cache: Int64? = nil, reported: Bool? = nil,
                      model: String = "cache-model", date: Date = now,
                      write: Int64? = nil, writeReported: Bool? = nil) throws -> ActivityEvent {
        var fields: [String: Any] = [
            "sessionId": "cache-session", "eventId": id, "timestamp": date.timeIntervalSince1970 * 1000,
            "usageContract": 1, "inputTokens": 10 + (cache ?? 0) + (write ?? 0), "outputTokens": 2, "model": model, "prompt": "never-retain"
        ]
        if let cache { fields["cacheReadTokens"] = cache }
        if let reported { fields["cacheReadTokensReported"] = reported }
        if let write { fields["cacheWriteTokens"] = write }
        if let writeReported { fields["cacheWriteTokensReported"] = writeReported }
        return try normalize(fields, date: date)
    }

    private static func normalize(_ fields: [String: Any], date: Date = now) throws -> ActivityEvent {
        try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: fields),
                                     source: .cli, hook: "usage", now: date)
    }

    static func accounting() throws {
        let base: [String: Any] = [
            "usageContract": 1, "sessionId": "accounting-session", "eventId": "accounting-call",
            "timestamp": now.timeIntervalSince1970 * 1000, "inputTokens": 1200, "outputTokens": 45,
            "model": "accounting-model", "reasoningTokens": 20
        ]
        let cases: [(Int64?, Int64?, Int64)] = [
            (900, 100, 200), (900, 0, 300), (900, nil, 300), (nil, nil, 1200),
            (900, 300, 0), (0, 100, 1100), (nil, 100, 1100), (0, 0, 1200)
        ]
        for (reads, writes, remainder) in cases {
            var fields = base
            fields["cacheReadTokensReported"] = reads != nil
            fields["cacheWriteTokensReported"] = writes != nil
            if let reads { fields["cacheReadTokens"] = reads }
            if let writes { fields["cacheWriteTokens"] = writes }
            let event = try normalize(fields)
            guard let tokens = event.tokens else { throw HistoryChecks.Failure(description: "Missing normalized counts") }
            try HistoryChecks.require(tokens.input == remainder && tokens.output == 45
                && tokens.cacheInput == (reads ?? 0) && tokens.cacheWrite == (writes ?? 0)
                && tokens.accountingVersion == TokenUsage.accountingVersion, "Four-bucket normalization")
            try HistoryChecks.require(tokens.breakdown.isIncomplete == (reads == nil || writes == nil),
                                      "Cache omission misclassified")
            let decoded = try JSONDecoder().decode(ActivityEvent.self, from: JSONEncoder().encode(event))
            try decoded.validate(now: now)
            try HistoryChecks.require(decoded == event, "IPC changed accounting or subtracted twice")
            var ledger = TokenLedger()
            for sample in [event, decoded] { try ledger.observe(sample, now: now) }
            guard let totals = ledger.totals else { throw HistoryChecks.Failure(description: "Missing ledger totals") }
            try HistoryChecks.require(totals.total == 1245 && totals.calls == 1
                && totals.input == remainder && totals.cacheWrite == (writes ?? 0)
                && totals.breakdown == tokens.breakdown, "Ledger overlap, coverage loss, or duplicate")
            try HistoryChecks.require(ledger.byModel.first?.tokens.total == 1245
                && ledger.bySession.first?.tokens?.total == 1245 && ledger.today(now: now)?.total == 1245,
                "Grouped total differs")

            let root = HistoryChecks.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var history: UsageHistoryStore? = try UsageHistoryStore(root: root, now: now)
            let interval = history!.clock.interval(.today, selected: now, now: now)
            try history!.record([event, decoded], now: now)
            history = nil
            history = try UsageHistoryStore(root: root, now: now)
            try history!.record([decoded], now: now)
            let saved = try history!.query(interval, model: "accounting-model")
            try HistoryChecks.require(saved.totals.total == 1245 && saved.totals.input == remainder
                && saved.totals.output == 45 && saved.totals.calls == 1
                && saved.totals.cacheWrite == (writes ?? 0) && saved.totals.breakdown == tokens.breakdown
                && saved.days.first?.tokens.breakdown == tokens.breakdown
                && saved.models.first?.tokens.breakdown == tokens.breakdown, "Persisted four-bucket accounting")
            var timeline: SessionTimelineStore? = try SessionTimelineStore(root: root, now: now)
            let session = timeline!.sessionID(source: .cli, hash: event.session)
            try timeline!.record([event, decoded], retention: .seven, now: now)
            timeline = nil
            timeline = try SessionTimelineStore(root: root, now: now)
            try timeline!.record([decoded], retention: .seven, now: now)
            let rows = try timeline!.events(session: session).events
            try HistoryChecks.require(rows.count == 1 && rows.first?.input == remainder
                && rows.first?.cacheWrite == (writes ?? 0) && rows.first?.breakdown == tokens.breakdown,
                "Timeline lost accounting after restart")
        }

        for pair in [(900, 301), (1201, 0), (0, 1201)] {
            try HistoryChecks.rejects("Overlapping cache amounts accepted") {
                _ = try normalize(base.merging(["cacheReadTokens": pair.0, "cacheWriteTokens": pair.1]) { _, new in new })
            }
        }
        for invalid in [NSNull(), true, "1", -1, 1.5, 1_000_000_001] as [Any] {
            try HistoryChecks.rejects("Malformed write count accepted") {
                _ = try normalize(base.merging(["cacheWriteTokens": invalid]) { _, new in new })
            }
        }
        for invalid in [NSNull(), "true", 0, 1] as [Any] {
            try HistoryChecks.rejects("Malformed write availability accepted") {
                _ = try normalize(base.merging(["cacheWriteTokensReported": invalid]) { _, new in new })
            }
        }
        for fields in [
            base.merging(["cacheWriteTokensReported": true]) { _, new in new },
            base.merging(["cacheWriteTokensReported": false, "cacheWriteTokens": 0]) { _, new in new }
        ] {
            try HistoryChecks.rejects("Inconsistent write availability accepted") { _ = try normalize(fields) }
        }
        for version in [nil, 0, 2, true, "1", NSNull()] as [Any?] {
            var fields = base
            fields["usageContract"] = version
            do {
                _ = try normalize(fields)
                throw HistoryChecks.Failure(description: "Old or unknown extension accepted")
            } catch TokenotchError.metricUpgrade {} // Compatibility must produce actionable upgrade guidance.
        }
        let valid = try normalize(base)
        guard var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any],
              let validTokens = payload["tokens"] as? [String: Any] else {
            throw HistoryChecks.Failure(description: "Missing usage envelope")
        }
        for version in [nil, 2] as [Int?] {
            var tokens = validTokens
            tokens["accountingVersion"] = version
            payload["tokens"] = tokens
            let event = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: payload))
            do {
                try event.validate(now: now)
                throw HistoryChecks.Failure(description: "Unmarked helper accepted")
            } catch TokenotchError.metricUpgrade {}
            var ledger = TokenLedger()
            try HistoryChecks.rejects("Old helper reached ledger") { try ledger.observe(event, now: now) }
        }
        let maximum = try normalize(base.merging([
            "inputTokens": 1_000_000_000, "outputTokens": 1_000_000_000,
            "cacheReadTokens": 500_000_000, "cacheWriteTokens": 500_000_000
        ]) { _, new in new })
        var ledger = TokenLedger()
        try ledger.observe(maximum, now: now)
        try HistoryChecks.require(ledger.totals?.total == 2_000_000_000 && ledger.totals?.input == 0, "Boundary sum")
    }

    static func contracts() throws {
        let samples: [(ActivityEvent, CacheInputCoverage.State)] = [
            (try event("missing", reported: false), .notReported),
            (try event("zero", cache: 0, reported: true), .reported),
            (try event("positive", cache: 99, reported: true), .reported),
            (try event("legacy-zero", cache: 0), .unknown),
            (try event("legacy-positive", cache: 42), .partial),
            (try event("legacy-absent"), .unknown)
        ]
        for (sample, state) in samples {
            try HistoryChecks.require(sample.tokens?.cacheCoverage.state == state, "Wrong cache availability")
            let data = try JSONEncoder().encode(sample)
            let decoded = try JSONDecoder().decode(ActivityEvent.self, from: data)
            try decoded.validate(now: now)
            try HistoryChecks.require(decoded == sample, "Cache provenance lost in IPC round trip")
            try HistoryChecks.require(!String(decoding: data, as: UTF8.self).contains("never-retain"), "Content retained")
        }
        let base: [String: Any] = ["usageContract": 1, "sessionId": "cache-session", "eventId": "invalid",
            "timestamp": now.timeIntervalSince1970 * 1000, "inputTokens": 10, "outputTokens": 2]
        for invalid in [NSNull(), "true", 1, 0] as [Any] {
            try HistoryChecks.rejects("Malformed cache marker accepted") {
                _ = try normalize(base.merging(["cacheReadTokensReported": invalid]) { _, new in new })
            }
        }
        for invalid in [NSNull(), true, "1", -1, 1.5, 1_000_000_001] as [Any] {
            try HistoryChecks.rejects("Malformed cache count accepted") {
                _ = try normalize(base.merging(["cacheReadTokensReported": true, "cacheReadTokens": invalid]) { _, new in new })
            }
        }
        try HistoryChecks.rejects("Reported count missing") { _ = try event("bad", reported: true) }
        try HistoryChecks.rejects("Unreported count supplied") { _ = try event("bad", cache: 0, reported: false) }
        let tokens = TokenUsage(callID: ActivityEvent.digest("decode"), input: 1, output: 2,
                                cacheInput: 0, cacheInputReported: true)
        guard let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens)) as? [String: Any] else {
            throw HistoryChecks.Failure(description: "Token fixture encoding")
        }
        var missing = encoded
        missing.removeValue(forKey: "cacheInput")
        for fields in [missing, encoded.merging(["cacheInputReported": NSNull()]) { _, new in new },
                       encoded.merging(["cacheInputReported": false, "cacheInput": 3]) { _, new in new }] {
            try HistoryChecks.rejects("Malformed normalized provenance accepted") {
                let sample = try JSONDecoder().decode(TokenUsage.self, from: JSONSerialization.data(withJSONObject: fields))
                try sample.validate()
            }
        }
    }

    static func aggregation() throws {
        let samples = try [event("a", cache: 30, reported: true, write: 7, writeReported: true),
                           event("b", cache: 0, reported: true, write: 0, writeReported: true),
                           event("c", reported: false, writeReported: false), event("d", cache: 5, write: 3)]
        var ledger = TokenLedger()
        for sample in samples + samples { try ledger.observe(sample, now: now) }
        guard let totals = ledger.totals else { throw HistoryChecks.Failure(description: "Missing cache totals") }
        try HistoryChecks.require(totals.calls == 4 && totals.input == 40 && totals.cacheInput == 35
                                  && totals.cacheWrite == 10 && totals.total == 93, "Cache deduplication")
        try HistoryChecks.require(totals.cacheWriteReportedCalls == 2 && totals.cacheWriteUnreportedCalls == 1
                                  && totals.breakdown.write.unknownCalls == 1, "Write coverage lost")
        try HistoryChecks.require(totals.cacheReportedCalls == 2 && totals.cacheUnreportedCalls == 1
                                  && totals.cacheCoverage.unknownCalls == 1 && totals.cacheCoverage.state == .partial,
                                  "Mixed cache coverage lost")
        try HistoryChecks.require(ledger.byModel.first?.tokens.cacheCoverage == totals.cacheCoverage
                                  && ledger.bySession.first?.tokens?.cacheCoverage == totals.cacheCoverage
                                  && ledger.today(now: now)?.cacheCoverage == totals.cacheCoverage,
                                  "Cache group coverage differs")
        let tomorrow = now.addingTimeInterval(86_400)
        try ledger.observe(event("tomorrow", reported: false, date: tomorrow), now: tomorrow)
        try HistoryChecks.require(ledger.totals?.cacheCoverage.state == .notReported, "Expired reporting retained")
        ledger.expire(now: tomorrow.addingTimeInterval(86_400))
        try HistoryChecks.require(ledger.totals == nil, "Expired cache totals retained")
        var capped = TokenLedger()
        try capped.observe(event("oldest", cache: 10, reported: true, write: 7, writeReported: true), now: now)
        for index in 0..<4096 {
            let date = now.addingTimeInterval(Double(index + 1) / 100)
            try capped.observe(event("cap-\(index)", reported: false, date: date, writeReported: false), now: date)
        }
        try HistoryChecks.require(capped.totals?.cacheInput == 0 && capped.totals?.cacheReportedCalls == 0
                                  && capped.totals?.cacheUnreportedCalls == 4096
                                  && capped.totals?.cacheWrite == 0 && capped.totals?.cacheWriteReportedCalls == 0
                                  && capped.totals?.cacheWriteUnreportedCalls == 4096, "Eviction left cache coverage behind")
    }

    static func persistence() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, now: now)
        let interval = store!.clock.interval(.today, selected: now, now: now)
        let samples = try [event("reported", cache: 13, reported: true), event("absent", reported: false),
                           event("legacy", cache: 0)]
        try store!.record(samples + samples, now: now)
        store = nil
        store = try UsageHistoryStore(root: root, now: now)
        try store!.record(samples, now: now)
        let snapshot = try store!.query(interval, model: "cache-model")
        try HistoryChecks.require(snapshot.totals.calls == 3 && snapshot.totals.cacheInput == 13
                                  && snapshot.totals.cacheReportedCalls == 1 && snapshot.totals.cacheUnreportedCalls == 1,
                                  "Persisted coverage or restart deduplication failed")
        try HistoryChecks.require(snapshot.days.first?.tokens.cacheCoverage == snapshot.totals.cacheCoverage
                                  && snapshot.models.first?.tokens.cacheCoverage == snapshot.totals.cacheCoverage,
                                  "Persisted group coverage differs")
        try store!.record((0..<102).map { try event("overflow-\($0)", reported: false, model: "model-\($0)") }, now: now)
        let overflow = try store!.query(interval)
        try HistoryChecks.require(overflow.models.first { $0.id == "*" }?.tokens.cacheCoverage.state == .notReported,
                                  "Overflow model coverage lost")
        store = nil
        var db: OpaquePointer?
        try HistoryChecks.require(sqlite3_open(root.appendingPathComponent("history/usage.sqlite").path, &db) == SQLITE_OK,
                                  "Open invalid-coverage fixture")
        defer { sqlite3_close(db) }
        try HistoryChecks.require(sqlite3_exec(db, """
            PRAGMA ignore_check_constraints=ON;
            UPDATE usage SET cache_reported_calls=calls+1 WHERE model='cache-model';
            """, nil, nil, nil) == SQLITE_OK, "Corrupt fixture coverage")
        let invalid = try UsageHistoryStore(root: root, now: now)
        try HistoryChecks.rejects("Impossible coverage accepted") { _ = try invalid.query(interval) }
    }

    static func migration() throws {
        for version in [1, 2, 3] {
            let root = HistoryChecks.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try PrivateFiles.directory(root)
            let directory = root.appendingPathComponent("history")
            try PrivateFiles.directory(directory)
            let file = directory.appendingPathComponent("usage.sqlite")
            try PrivateFiles.write(Data(), to: file)
            var db: OpaquePointer?
            try HistoryChecks.require(sqlite3_open(file.path, &db) == SQLITE_OK, "Open legacy fixture")
            let cacheColumn = version >= 2 ? "cache_input INTEGER NOT NULL DEFAULT 0," : ""
            let cacheName = version >= 2 ? ",cache_input" : ""
            let cacheValue = version >= 2 ? ",7" : ""
            let coverageColumns = version == 3
                ? "cache_reported_calls INTEGER NOT NULL DEFAULT 2,cache_unreported_calls INTEGER NOT NULL DEFAULT 0," : ""
            let sql = """
                CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                INSERT INTO metadata VALUES ('zone','GMT'),('began','\(now.timeIntervalSince1970)');
                CREATE TABLE usage(day TEXT NOT NULL,model TEXT NOT NULL,input INTEGER NOT NULL DEFAULT 0,
                    output INTEGER NOT NULL DEFAULT 0,\(cacheColumn)\(coverageColumns)calls INTEGER NOT NULL DEFAULT 0,
                    first_sum REAL NOT NULL DEFAULT 0,first_count INTEGER NOT NULL DEFAULT 0,
                    duration_sum REAL NOT NULL DEFAULT 0,duration_count INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,model));
                INSERT INTO usage(day,model,input,output,calls\(cacheName)) VALUES ('2026-09-21','cache-model',100,20,2\(cacheValue));
                CREATE TABLE context(day TEXT PRIMARY KEY,maximum REAL,completed INTEGER NOT NULL DEFAULT 0,
                    failed INTEGER NOT NULL DEFAULT 0,seen INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE coverage(day TEXT PRIMARY KEY,seconds REAL NOT NULL DEFAULT 0,gap INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE receipts(id TEXT PRIMARY KEY,time REAL NOT NULL);
                CREATE INDEX receipts_time ON receipts(time);
                PRAGMA user_version=\(version);
                """
            let result = sqlite3_exec(db, sql, nil, nil, nil)
            sqlite3_close(db)
            try HistoryChecks.require(result == SQLITE_OK, "Create legacy fixture")
            var store: UsageHistoryStore? = try UsageHistoryStore(root: root, now: now)
            let interval = store!.clock.interval(.today, selected: now, now: now)
            let legacy = try store!.query(interval).totals
            try HistoryChecks.require(legacy.input == 100 && legacy.output == 20 && legacy.calls == 2
                                      && legacy.cacheInput == (version >= 2 ? 7 : 0)
                                      && legacy.cacheCoverage.unknownCalls == (version == 3 ? 0 : 2)
                                      && legacy.unverifiedCalls == 2 && legacy.cacheWrite == 0
                                      && legacy.breakdown.write.state == .unknown,
                                      "Migration fabricated coverage or lost values")
            try HistoryChecks.require(legacy.cacheCoverage.state == (version == 3 ? .reported : version == 2 ? .partial : .unknown),
                                      "Legacy cache state misrepresented")
            let sample = try event("new", cache: 0, reported: true, write: 3, writeReported: true)
            try store!.record([sample], now: now)
            store = nil
            store = try UsageHistoryStore(root: root, now: now)
            try store!.record([sample], now: now)
            let combined = try store!.query(interval).totals
            try HistoryChecks.require(combined.calls == 3 && combined.cacheReportedCalls == (version == 3 ? 3 : 1)
                                      && combined.unverifiedCalls == 2 && combined.input == 110
                                      && combined.cacheWrite == 3 && combined.cacheWriteReportedCalls == 1
                                      && combined.cacheCoverage.unknownCalls == (version == 3 ? 0 : 2),
                                      "Post-migration coverage changed after restart")
            store = nil
            try HistoryChecks.require(sqlite3_open(file.path, &db) == SQLITE_OK, "Open partition fixture")
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement); sqlite3_close(db) }
            try HistoryChecks.require(sqlite3_prepare_v2(db,
                "SELECT count(*),sum(accounting) FROM usage WHERE model='cache-model'", -1, &statement, nil) == SQLITE_OK
                && sqlite3_step(statement) == SQLITE_ROW
                && sqlite3_column_int64(statement, 0) == 2 && sqlite3_column_int64(statement, 1) == 1,
                "Legacy and corrected daily values merged")
        }
    }

    static func timeline() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: SessionTimelineStore? = try SessionTimelineStore(root: root, now: now)
        let samples = try [event("a", cache: 0, reported: true), event("b", reported: false),
                           event("c", cache: 0), event("d", cache: 9)]
        let session = store!.sessionID(source: .cli, hash: samples[0].session)
        try store!.record(samples + samples, retention: .seven, now: now)
        store = nil
        store = try SessionTimelineStore(root: root, now: now)
        let saved = try store!.events(session: session).events
        try HistoryChecks.require(saved.count == 4, "Timeline cache duplicate")
        for state in [CacheInputCoverage.State.reported, .notReported, .unknown, .partial] {
            try HistoryChecks.require(saved.contains { $0.cacheCoverage?.state == state }, "Timeline lost cache state")
        }
        guard let zero = saved.first(where: { $0.cacheInputReported == true }),
              let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(zero)) as? [String: Any] else {
            throw HistoryChecks.Failure(description: "Missing timeline fixture")
        }
        for invalid in [NSNull(), "true", 1] as [Any] {
            try HistoryChecks.rejects("Invalid timeline cache flag accepted") {
                let data = try JSONSerialization.data(withJSONObject: object.merging(["cacheInputReported": invalid]) { _, new in new })
                let event = try JSONDecoder().decode(TimelineEvent.self, from: data)
                try event.validate()
            }
        }
        var missing = object
        missing.removeValue(forKey: "cacheInput")
        try HistoryChecks.rejects("Timeline reported count absent") {
            try JSONDecoder().decode(TimelineEvent.self, from: JSONSerialization.data(withJSONObject: missing)).validate()
        }
    }

    static func legacyTimeline() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: SessionTimelineStore? = try SessionTimelineStore(root: root, now: now)
        let original = try event("old", cache: 900, reported: true)
        let session = store!.sessionID(source: .cli, hash: original.session)
        try store!.record([original], retention: .seven, now: now)
        let id = try store!.events(session: session).events.first?.id
        store = nil
        var db: OpaquePointer?
        let file = root.appendingPathComponent("timeline/sessions.sqlite")
        try HistoryChecks.require(sqlite3_open(file.path, &db) == SQLITE_OK, "Open old timeline fixture")
        let result = sqlite3_exec(db, """
            UPDATE events SET payload=json_set(
              json_remove(payload,'$.accountingVersion','$.cacheWrite','$.cacheWriteReported'),'$.input',1200);
            PRAGMA user_version=1;
            """, nil, nil, nil)
        sqlite3_close(db)
        try HistoryChecks.require(result == SQLITE_OK, "Create old timeline fixture")
        for _ in 0..<2 {
            store = try SessionTimelineStore(root: root, now: now)
            let old = try store!.events(session: session).events.first { $0.id == id }
            try HistoryChecks.require(old?.input == 1200 && old?.cacheInput == 900
                && old?.accountingVersion == nil && old?.breakdown?.unverifiedCalls == 1
                && old?.breakdown?.write.state == .unknown, "Legacy timeline was guessed or rewritten")
            let fresh = try event("new", cache: 900, reported: true)
            try store!.record([fresh, fresh], retention: .seven, now: now)
            let rows = try store!.events(session: session).events
            try HistoryChecks.require(rows.count == 2
                && rows.first { $0.id != id }?.breakdown?.unverifiedCalls == 0,
                "Mixed timeline provenance or deduplication lost")
            store = nil
        }
    }

    static func migrationRollback() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFiles.directory(root)
        let directory = root.appendingPathComponent("history")
        try PrivateFiles.directory(directory)
        let file = directory.appendingPathComponent("usage.sqlite")
        try PrivateFiles.write(Data(), to: file)
        var db: OpaquePointer?
        try HistoryChecks.require(sqlite3_open(file.path, &db) == SQLITE_OK, "Open failing migration fixture")
        let result = sqlite3_exec(db, """
            CREATE TABLE usage(day TEXT,model TEXT,input INTEGER,output INTEGER,cache_input INTEGER,calls INTEGER,
              cache_reported_calls INTEGER,cache_unreported_calls INTEGER,first_sum REAL,first_count INTEGER,
              duration_sum REAL,duration_count INTEGER);
            INSERT INTO usage VALUES ('2026-09-21','invalid',-1,45,900,1,1,0,0,0,0,0);
            PRAGMA user_version=3;
            """, nil, nil, nil)
        sqlite3_close(db)
        try HistoryChecks.require(result == SQLITE_OK, "Create failing migration fixture")
        try HistoryChecks.rejects("Failed migration became empty success") { _ = try UsageHistoryStore(root: root, now: now) }
        try HistoryChecks.require(sqlite3_open(file.path, &db) == SQLITE_OK, "Reopen failed migration")
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try HistoryChecks.require(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK
            && sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 3,
            "Failed migration advanced version")
        sqlite3_finalize(statement)
        try HistoryChecks.require(sqlite3_prepare_v2(db, "SELECT input FROM usage", -1, &statement, nil) == SQLITE_OK
            && sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == -1,
            "Failed migration modified source records")
        sqlite3_finalize(statement)
        try HistoryChecks.require(sqlite3_prepare_v2(db,
            "SELECT count(*) FROM sqlite_master WHERE name='usage_v4'", -1, &statement, nil) == SQLITE_OK
            && sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 0,
            "Failed migration left a partial table")
        sqlite3_finalize(statement)
    }

    static func run() throws {
        try accounting()
        try contracts()
        try aggregation()
        try persistence()
        try migration()
        try timeline()
        try legacyTimeline()
        try migrationRollback()
        print("PASS: disjoint four-category accounting, cache reporting, live aggregation, legacy migration/rollback, persistence and timelines")
    }
}
