import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Confine each instance to a single serial executor.
public final class UsageHistoryStore {
    private var database: OpaquePointer?
    private let directory: URL
    public private(set) var clock: HistoryCalendar
    public private(set) var began: Date
    public private(set) var hourlyBegan: Date
    private var receiptKey = SymmetricKey(size: .bits256)
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL, zone: TimeZone = .current, now: Date = Date()) throws {
        try Self.validateDate(now)
        directory = root.appendingPathComponent("history", isDirectory: true)
        clock = HistoryCalendar(zone: zone)
        began = now
        hourlyBegan = now
        try PrivateFiles.directory(root)
        try PrivateFiles.directory(directory)
        let file = directory.appendingPathComponent("usage.sqlite")
        try validateFiles()
        if !FileManager.default.fileExists(atPath: file.path) {
            try PrivateFiles.write(Data(), to: file)
        }
        // macOS temporary directories may live beneath the system /var symlink.
        // Resolve ancestors only after validating our private directory and leaf.
        guard let canonical = realpath(directory.path, nil) else { throw TokenotchError.unsafePath }
        let openPath = String(cString: canonical) + "/" + file.lastPathComponent
        free(canonical)
        guard sqlite3_open_v2(openPath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw HistoryError.storage
        }
        do {
            sqlite3_busy_timeout(database, 1000)
            let version = try scalar("PRAGMA user_version")
            guard version <= 6 else { throw HistoryError.schema }
            guard version >= 0 else { throw HistoryError.invalid }
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                if version == 0 {
                    try execute("""
                    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE usage (
                      day TEXT NOT NULL, model TEXT NOT NULL,
                      input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(input)='integer' AND input>=0),
                      output INTEGER NOT NULL DEFAULT 0 CHECK(typeof(output)='integer' AND output>=0),
                      cache_input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(cache_input)='integer' AND cache_input>=0),
                      calls INTEGER NOT NULL DEFAULT 0 CHECK(typeof(calls)='integer' AND calls>=0),
                      cache_reported_calls INTEGER NOT NULL DEFAULT 0
                        CHECK(typeof(cache_reported_calls)='integer' AND cache_reported_calls>=0),
                      cache_unreported_calls INTEGER NOT NULL DEFAULT 0
                        CHECK(typeof(cache_unreported_calls)='integer' AND cache_unreported_calls>=0
                          AND cache_reported_calls<=calls AND cache_unreported_calls<=calls-cache_reported_calls),
                      first_sum REAL NOT NULL DEFAULT 0, first_count INTEGER NOT NULL DEFAULT 0,
                      duration_sum REAL NOT NULL DEFAULT 0, duration_count INTEGER NOT NULL DEFAULT 0,
                      PRIMARY KEY(day, model));
                    CREATE TABLE context (
                      day TEXT PRIMARY KEY, maximum REAL, completed INTEGER NOT NULL DEFAULT 0,
                      failed INTEGER NOT NULL DEFAULT 0, seen INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE coverage (day TEXT PRIMARY KEY, seconds REAL NOT NULL DEFAULT 0, gap INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE receipts (id TEXT PRIMARY KEY, time REAL NOT NULL);
                    CREATE INDEX receipts_time ON receipts(time);
                    PRAGMA user_version=3;
                    """)
                    try set("zone", zone.identifier)
                    try set("began", String(now.timeIntervalSince1970))
                } else if version < 3 {
                    if version == 1 {
                        try execute("""
                        ALTER TABLE usage ADD COLUMN cache_input INTEGER NOT NULL DEFAULT 0
                          CHECK(typeof(cache_input)='integer' AND cache_input>=0);
                        """)
                    }
                    try execute("""
                    ALTER TABLE usage ADD COLUMN cache_reported_calls INTEGER NOT NULL DEFAULT 0
                      CHECK(typeof(cache_reported_calls)='integer' AND cache_reported_calls>=0);
                    ALTER TABLE usage ADD COLUMN cache_unreported_calls INTEGER NOT NULL DEFAULT 0
                      CHECK(typeof(cache_unreported_calls)='integer' AND cache_unreported_calls>=0
                        AND cache_reported_calls<=calls AND cache_unreported_calls<=calls-cache_reported_calls);
                    PRAGMA user_version=3;
                    """)
                }
                if version < 4 {
                    try execute("""
                    CREATE TABLE usage_v4 (
                      day TEXT NOT NULL, model TEXT NOT NULL,
                      accounting INTEGER NOT NULL CHECK(typeof(accounting)='integer' AND accounting IN (0,1)),
                      input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(input)='integer' AND input>=0),
                      output INTEGER NOT NULL DEFAULT 0 CHECK(typeof(output)='integer' AND output>=0),
                      cache_input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(cache_input)='integer' AND cache_input>=0),
                      calls INTEGER NOT NULL DEFAULT 0 CHECK(typeof(calls)='integer' AND calls>=0),
                      cache_reported_calls INTEGER NOT NULL DEFAULT 0
                        CHECK(typeof(cache_reported_calls)='integer' AND cache_reported_calls>=0),
                      cache_unreported_calls INTEGER NOT NULL DEFAULT 0
                        CHECK(typeof(cache_unreported_calls)='integer' AND cache_unreported_calls>=0
                          AND cache_reported_calls<=calls AND cache_unreported_calls<=calls-cache_reported_calls),
                      cache_write INTEGER NOT NULL DEFAULT 0 CHECK(typeof(cache_write)='integer' AND cache_write>=0),
                      write_reported_calls INTEGER NOT NULL DEFAULT 0
                        CHECK(typeof(write_reported_calls)='integer' AND write_reported_calls>=0),
                      write_unreported_calls INTEGER NOT NULL DEFAULT 0
                        CHECK(typeof(write_unreported_calls)='integer' AND write_unreported_calls>=0
                          AND write_reported_calls<=calls AND write_unreported_calls<=calls-write_reported_calls),
                      first_sum REAL NOT NULL DEFAULT 0, first_count INTEGER NOT NULL DEFAULT 0,
                      duration_sum REAL NOT NULL DEFAULT 0, duration_count INTEGER NOT NULL DEFAULT 0,
                      PRIMARY KEY(day,model,accounting));
                    INSERT INTO usage_v4(day,model,accounting,input,output,cache_input,calls,
                      cache_reported_calls,cache_unreported_calls,first_sum,first_count,duration_sum,duration_count)
                    SELECT day,model,0,input,output,cache_input,calls,
                      cache_reported_calls,cache_unreported_calls,first_sum,first_count,duration_sum,duration_count FROM usage;
                    DROP TABLE usage;
                    ALTER TABLE usage_v4 RENAME TO usage;
                    PRAGMA user_version=4;
                    """)
                }
                if version < 5 {
                    try execute("""
                    CREATE TABLE hourly_usage (
                      start REAL PRIMARY KEY NOT NULL,
                      tokens INTEGER NOT NULL DEFAULT 0 CHECK(typeof(tokens)='integer' AND tokens>=0),
                      calls INTEGER NOT NULL DEFAULT 0 CHECK(typeof(calls)='integer' AND calls>=0),
                      seconds REAL NOT NULL DEFAULT 0 CHECK(seconds>=0),
                      gap INTEGER NOT NULL DEFAULT 0 CHECK(gap IN (0,1)));
                    PRAGMA user_version=5;
                    """)
                    try set("hourly_began", String(now.timeIntervalSince1970))
                }
                if version < 6 { try migrateSources() }
                guard let zoneName = try get("zone"), let storedZone = TimeZone(identifier: zoneName),
                      let start = try get("began").flatMap(Double.init),
                      let hourlyStart = try get("hourly_began").flatMap(Double.init),
                      let encodedKey = try get("receipt_key"),
                      let keyData = Data(base64Encoded: encodedKey), keyData.count == 32 else {
                    throw HistoryError.invalid
                }
                clock = HistoryCalendar(zone: storedZone)
                began = Date(timeIntervalSince1970: start)
                hourlyBegan = Date(timeIntervalSince1970: hourlyStart)
                try Self.validateDate(began)
                try Self.validateDate(hourlyBegan)
                receiptKey = SymmetricKey(data: keyData)
                try pruneReceipts(now: now)
                for source in UsageSource.allCases {
                    if let last = try checkpoint("active", source: source) {
                        try writeGap(at: last, sources: [source])
                        try set(checkpointKey("active", source: source), "")
                    }
                    if let paused = try checkpoint("inactive_since", source: source) {
                        try writeGap(at: paused, sources: [source])
                        try writeGap(at: now, sources: [source])
                    }
                }
                try pruneHourlyHistory(now: now)
                try validateFiles()
            }
        } catch {
            sqlite3_close(database); database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    private func migrateSources() throws {
        try execute("""
        CREATE TABLE usage_v6 (
          day TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'cli' CHECK(source IN ('cli','vscodeLocal','vscodeCopilot')),
          model TEXT NOT NULL, accounting INTEGER NOT NULL CHECK(typeof(accounting)='integer' AND accounting IN (0,1)),
          input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(input)='integer' AND input>=0),
          output INTEGER NOT NULL DEFAULT 0 CHECK(typeof(output)='integer' AND output>=0),
          cache_input INTEGER NOT NULL DEFAULT 0 CHECK(typeof(cache_input)='integer' AND cache_input>=0),
          calls INTEGER NOT NULL DEFAULT 0 CHECK(typeof(calls)='integer' AND calls>=0),
          cache_reported_calls INTEGER NOT NULL DEFAULT 0
            CHECK(typeof(cache_reported_calls)='integer' AND cache_reported_calls>=0 AND cache_reported_calls<=calls),
          cache_unreported_calls INTEGER NOT NULL DEFAULT 0
            CHECK(typeof(cache_unreported_calls)='integer' AND cache_unreported_calls>=0
              AND cache_unreported_calls<=calls-cache_reported_calls),
          cache_write INTEGER NOT NULL DEFAULT 0 CHECK(typeof(cache_write)='integer' AND cache_write>=0),
          write_reported_calls INTEGER NOT NULL DEFAULT 0
            CHECK(typeof(write_reported_calls)='integer' AND write_reported_calls>=0 AND write_reported_calls<=calls),
          write_unreported_calls INTEGER NOT NULL DEFAULT 0
            CHECK(typeof(write_unreported_calls)='integer' AND write_unreported_calls>=0
              AND write_unreported_calls<=calls-write_reported_calls),
          first_sum REAL NOT NULL DEFAULT 0 CHECK(first_sum>=0 AND first_sum<=1.7976931348623157e308),
          first_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(first_count)='integer' AND first_count BETWEEN 0 AND calls),
          duration_sum REAL NOT NULL DEFAULT 0 CHECK(duration_sum>=0 AND duration_sum<=1.7976931348623157e308),
          duration_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(duration_count)='integer' AND duration_count BETWEEN 0 AND calls),
          CHECK(typeof(input+output+cache_input+cache_write)='integer'),
          PRIMARY KEY(day,source,model,accounting));
        INSERT INTO usage_v6
          SELECT day,'cli',model,accounting,input,output,cache_input,calls,
            cache_reported_calls,cache_unreported_calls,cache_write,write_reported_calls,write_unreported_calls,
            first_sum,first_count,duration_sum,duration_count FROM usage;
        DROP TABLE usage;
        ALTER TABLE usage_v6 RENAME TO usage;
        CREATE TABLE context_v6 (
          day TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'cli' CHECK(source IN ('cli','vscodeLocal','vscodeCopilot')),
          maximum REAL CHECK(maximum>=0 AND maximum<=1.7976931348623157e308),
          completed INTEGER NOT NULL DEFAULT 0 CHECK(typeof(completed)='integer' AND completed>=0),
          failed INTEGER NOT NULL DEFAULT 0 CHECK(typeof(failed)='integer' AND failed>=0),
          seen INTEGER NOT NULL DEFAULT 0 CHECK(seen IN (0,1)), PRIMARY KEY(day,source));
        INSERT INTO context_v6 SELECT day,'cli',maximum,completed,failed,seen FROM context;
        DROP TABLE context;
        ALTER TABLE context_v6 RENAME TO context;
        CREATE TABLE coverage_v6 (
          day TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'cli' CHECK(source IN ('cli','vscodeLocal','vscodeCopilot','all')),
          seconds REAL NOT NULL DEFAULT 0 CHECK(seconds BETWEEN 0 AND 86400000),
          gap INTEGER NOT NULL DEFAULT 0 CHECK(gap IN (0,1)),
          imported INTEGER NOT NULL DEFAULT 0 CHECK(imported IN (0,1)), PRIMARY KEY(day,source));
        INSERT INTO coverage_v6(day,source,seconds,gap) SELECT day,'cli',seconds,gap FROM coverage;
        INSERT INTO coverage_v6(day,source,seconds,gap) SELECT day,'all',seconds,gap FROM coverage;
        DROP TABLE coverage;
        ALTER TABLE coverage_v6 RENAME TO coverage;
        CREATE TABLE hourly_usage_v6 (
          start REAL NOT NULL CHECK(typeof(start) IN ('real','integer') AND start>=-62135596800 AND start<253402300800),
          source TEXT NOT NULL DEFAULT 'cli' CHECK(source IN ('cli','vscodeLocal','vscodeCopilot','all')),
          tokens INTEGER NOT NULL DEFAULT 0 CHECK(typeof(tokens)='integer' AND tokens>=0),
          calls INTEGER NOT NULL DEFAULT 0 CHECK(typeof(calls)='integer' AND calls>=0),
          seconds REAL NOT NULL DEFAULT 0 CHECK(seconds BETWEEN 0 AND 86400000),
          gap INTEGER NOT NULL DEFAULT 0 CHECK(gap IN (0,1)),
          CHECK(source!='all' OR (tokens=0 AND calls=0)), PRIMARY KEY(start,source));
        INSERT INTO hourly_usage_v6 SELECT start,'cli',tokens,calls,seconds,gap FROM hourly_usage;
        INSERT INTO hourly_usage_v6(start,source,seconds,gap)
          SELECT start,'all',seconds,gap FROM hourly_usage WHERE seconds>0 OR gap=1;
        DROP TABLE hourly_usage;
        ALTER TABLE hourly_usage_v6 RENAME TO hourly_usage;
        CREATE TABLE durable_receipts (id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=64));
        CREATE TABLE coverage_intervals (
          day TEXT NOT NULL, source TEXT NOT NULL CHECK(source IN ('cli','vscodeLocal','vscodeCopilot','all')),
          start REAL NOT NULL, end REAL NOT NULL CHECK(end>start), PRIMARY KEY(day,source,start));
        PRAGMA user_version=6;
        """)
        try set("receipt_key", receiptKey.withUnsafeBytes { Data($0).base64EncodedString() })
    }

    private static func validateDate(_ date: Date) throws {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= -62_135_596_800, value < 253_402_300_800 else {
            throw HistoryError.invalid
        }
    }

    private func checkpointKey(_ name: String, source: UsageSource) -> String {
        source == .cli ? name : "\(name):\(source.rawValue)"
    }

    private func checkpoint(_ name: String, source: UsageSource) throws -> Date? {
        guard let value = try get(checkpointKey(name, source: source)), !value.isEmpty else { return nil }
        guard let time = Double(value) else { throw HistoryError.invalid }
        let date = Date(timeIntervalSince1970: time)
        try Self.validateDate(date)
        return date
    }

    private func validateFiles() throws {
        try Self.validateFiles(in: directory)
    }

    private static func validateFiles(in directory: URL) throws {
        for name in ["usage.sqlite", "usage.sqlite-journal", "usage.sqlite-wal", "usage.sqlite-shm"] {
            var info = stat()
            let path = directory.appendingPathComponent(name).path
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else { throw TokenotchError.unsafePath }
                continue
            }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0 else { throw TokenotchError.unsafePath }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.storage }
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw HistoryError.storage
        }
        for (index, value) in values.enumerated() {
            if sqlite3_bind_text(result, Int32(index + 1), value, -1, transient) != SQLITE_OK {
                sqlite3_finalize(result); throw HistoryError.storage
            }
        }
        return result
    }
    private func run(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw HistoryError.storage }
    }
    private func scalar(_ sql: String, _ values: [String] = []) throws -> Int64 {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw HistoryError.storage }
        return sqlite3_column_int64(s, 0)
    }
    private func text(_ s: OpaquePointer, _ column: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(s, column) else { throw HistoryError.invalid }
        return String(cString: pointer)
    }
    private func get(_ key: String) throws -> String? {
        let s = try statement("SELECT value FROM metadata WHERE key=?", [key]); defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw HistoryError.storage }
        return try text(s, 0)
    }
    private func set(_ key: String, _ value: String) throws {
        try run("INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch {
            guard sqlite3_exec(database, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw HistoryError.storage }
            throw error
        }
    }

    private func pruneReceipts(now: Date) throws {
        try run("DELETE FROM receipts WHERE time < ? OR time > ?",
                [String(now.addingTimeInterval(-600).timeIntervalSince1970),
                 String(now.addingTimeInterval(30).timeIntervalSince1970)])
    }

    private func validate(_ event: ActivityEvent, now: Date, importing: Bool) throws {
        try event.validatePayload()
        try Self.validateDate(event.timestamp)
        guard event.kind.isMetric, event.kind != .contextInvalidated,
              event.source == .cli || (event.kind == .usage && event.metricSource != nil),
              !importing || event.usageSource != .cli,
              event.timestamp <= now.addingTimeInterval(importing ? 0 : 30) else {
            throw TokenotchError.invalidEvent
        }
    }

    private func receiptID(_ event: ActivityEvent) -> String {
        let id = event.tokens?.callID ?? event.metricID ?? event.id
        guard event.usageSource != .cli else { return id }
        return HMAC<SHA256>.authenticationCode(
            for: Data("\(event.usageSource.rawValue):\(id)".utf8), using: receiptKey)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Preview imports without creating receipts or changing coverage.
    public func countNew(_ events: [ActivityEvent]) throws -> Int {
        try validateFiles()
        let now = Date()
        var ids = Set<String>()
        var count = 0
        for event in events {
            try validate(event, now: now, importing: true)
            let id = receiptID(event)
            if ids.insert(id).inserted,
               try scalar("SELECT count(*) FROM durable_receipts WHERE id=?", [id]) == 0 { count += 1 }
        }
        return count
    }

    @discardableResult
    public func record(_ events: [ActivityEvent], now: Date = Date(), importing: Bool = false) throws -> Int {
        try validateFiles()
        try Self.validateDate(now)
        let hourlyCutoff = clock.interval(.week, selected: now, now: now).start
        var inserted = 0
        try transaction {
            try pruneReceipts(now: now)
            for event in events {
                // Admission happened before enqueue; queued work must still have valid fields.
                try validate(event, now: now, importing: importing)
                let id = receiptID(event)
                if event.usageSource == .cli {
                    try run("INSERT INTO receipts VALUES (?,?) ON CONFLICT(id) DO NOTHING",
                            [id, String(now.timeIntervalSince1970)])
                } else {
                    try run("INSERT INTO durable_receipts VALUES (?) ON CONFLICT(id) DO NOTHING", [id])
                }
                guard sqlite3_changes(database) != 0 else { continue }
                inserted += 1
                let day = clock.key(event.timestamp)
                let source = event.usageSource.rawValue
                let includeHourly = event.timestamp >= hourlyCutoff && (importing || event.timestamp >= hourlyBegan)
                if let tokens = event.tokens {
                    var model = tokens.model ?? ""
                    let exists = try scalar("SELECT count(*) FROM usage WHERE day=? AND model=?", [day, model]) > 0
                    if !exists {
                        if try scalar("SELECT count(DISTINCT model) FROM usage WHERE day=?", [day]) >= 100 { model = "*" }
                    }
                    try run("""
                    INSERT INTO usage(day,source,model,input,output,cache_input,calls,first_sum,first_count,duration_sum,duration_count,
                      cache_reported_calls,cache_unreported_calls,accounting,cache_write,write_reported_calls,write_unreported_calls)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
                    ON CONFLICT(day,source,model,accounting) DO UPDATE SET
                      input=input+excluded.input, output=output+excluded.output,
                      cache_input=cache_input+excluded.cache_input, calls=calls+excluded.calls,
                      cache_reported_calls=cache_reported_calls+excluded.cache_reported_calls,
                      cache_unreported_calls=cache_unreported_calls+excluded.cache_unreported_calls,
                      cache_write=cache_write+excluded.cache_write,
                      write_reported_calls=write_reported_calls+excluded.write_reported_calls,
                      write_unreported_calls=write_unreported_calls+excluded.write_unreported_calls,
                      first_sum=first_sum+excluded.first_sum, first_count=first_count+excluded.first_count,
                      duration_sum=duration_sum+excluded.duration_sum, duration_count=duration_count+excluded.duration_count
                    """, [day, source, model, String(tokens.input), String(tokens.output), String(tokens.cacheInput), "1",
                          String(tokens.timeToFirstTokenMs ?? 0), tokens.timeToFirstTokenMs == nil ? "0" : "1",
                          String(tokens.durationMs ?? 0), tokens.durationMs == nil ? "0" : "1",
                          tokens.cacheInputReported == true ? "1" : "0", tokens.cacheInputReported == false ? "1" : "0",
                          String(tokens.cacheWrite), tokens.cacheWriteReported == true ? "1" : "0",
                          tokens.cacheWriteReported == false ? "1" : "0"])
                    if includeHourly {
                        try run("""
                        INSERT INTO hourly_usage(start,source,tokens,calls) VALUES (?,?,?,1)
                        ON CONFLICT(start,source) DO UPDATE SET tokens=tokens+excluded.tokens,calls=calls+1
                        """, [String(clock.hour(containing: event.timestamp).start.timeIntervalSince1970),
                              source, String(tokens.input + tokens.output + tokens.cacheInput + tokens.cacheWrite)])
                    }
                }
                if let context = event.context {
                    try run("""
                    INSERT INTO context(day,source,maximum) VALUES (?,?,?)
                    ON CONFLICT(day,source) DO UPDATE SET maximum=max(coalesce(maximum,0),excluded.maximum)
                    """, [day, source, String(context.fraction)])
                }
                if let compaction = event.compaction, let success = compaction.success {
                    try run("""
                    INSERT INTO context(day,source,completed,failed,seen) VALUES (?,?,?,?,1)
                    ON CONFLICT(day,source) DO UPDATE SET completed=completed+excluded.completed,
                      failed=failed+excluded.failed, seen=1
                    """, [day, source, success ? "1" : "0", success ? "0" : "1"])
                }
                if importing {
                    try writeGap(at: event.timestamp, sources: [event.usageSource],
                                 imported: true, includeHourly: includeHourly)
                }
            }
            try pruneHourlyHistory(now: now)
        }
        return inserted
    }

    public func markGap(at date: Date, sources: Set<UsageSource> = [.cli]) throws {
        try validateFiles()
        try Self.validateDate(date)
        try transaction { try writeGap(at: date, sources: sources) }
    }

    private func writeGap(at date: Date, sources: Set<UsageSource>, imported: Bool = false,
                          includeHourly: Bool? = nil) throws {
        guard !sources.isEmpty else { return }
        for source in sources.map(\.rawValue).sorted() + ["all"] {
            try run("""
            INSERT INTO coverage(day,source,gap,imported) VALUES (?,?,1,?)
            ON CONFLICT(day,source) DO UPDATE SET gap=1,imported=max(imported,excluded.imported)
            """, [clock.key(date), source, imported ? "1" : "0"])
            if includeHourly ?? (date >= hourlyBegan) {
                try run("""
                INSERT INTO hourly_usage(start,source,gap) VALUES (?,?,1)
                ON CONFLICT(start,source) DO UPDATE SET gap=1
                """, [String(clock.hour(containing: date).start.timeIntervalSince1970), source])
            }
        }
    }

    public func heartbeat(from start: Date, to end: Date, active: Bool,
                          sources: Set<UsageSource> = [.cli]) throws {
        try validateFiles()
        try Self.validateDate(start)
        try Self.validateDate(end)
        try transaction {
            for source in sources {
                if active, let paused = try checkpoint("inactive_since", source: source) {
                    try writeGap(at: paused, sources: [source])
                    try writeGap(at: start, sources: [source])
                    try set(checkpointKey("inactive_since", source: source), "")
                }
            }
            var cursor = start
            // Long sleep/clock changes are a gap, not continuously observed coverage.
            if end.timeIntervalSince(start) > 65 || end < start {
                try writeGap(at: start, sources: sources)
                try writeGap(at: end, sources: sources)
                cursor = end
            }
            while cursor < end {
                let hour = clock.hour(containing: cursor)
                let next = min(end, hour.end)
                if !sources.isEmpty {
                    for source in sources.map(\.rawValue).sorted() + ["all"] {
                        try recordCoverage(from: cursor, to: next, source: source)
                    }
                }
                cursor = next
            }
            for source in sources {
                try set(checkpointKey("active", source: source), active ? String(end.timeIntervalSince1970) : "")
                if !active {
                    try set(checkpointKey("inactive_since", source: source), String(end.timeIntervalSince1970))
                }
            }
            try pruneReceipts(now: end)
            try pruneHourlyHistory(now: end)
            if !active && sources.contains(.cli) {
                try execute("DELETE FROM receipts")
            }
        }
    }

    // These are coalesced collection checkpoints, never request/session spans.
    // Legacy coverage has no positions; retain that baseline and cap new unions at the bucket's opportunity.
    private func recordCoverage(from start: Date, to end: Date, source: String) throws {
        let day = clock.key(start), hour = clock.hour(containing: start)
        let low = start.timeIntervalSince1970, high = end.timeIntervalSince1970
        let hourlyLow = max(low, hourlyBegan.timeIntervalSince1970)
        var mergedLow = low, mergedHigh = high
        var seconds = high - low, hourlySeconds = max(0, high - hourlyLow)
        let s = try statement("""
        SELECT start,end FROM coverage_intervals WHERE day=? AND source=? AND start<=? AND end>=? ORDER BY start
        """, [day, source, String(high), String(low)])
        defer { sqlite3_finalize(s) }
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryError.storage }
            let a = sqlite3_column_double(s, 0), b = sqlite3_column_double(s, 1)
            guard a.isFinite, b.isFinite, b > a else { throw HistoryError.invalid }
            mergedLow = min(mergedLow, a); mergedHigh = max(mergedHigh, b)
            seconds -= max(0, min(high, b) - max(low, a))
            hourlySeconds -= max(0, min(high, b) - max(hourlyLow, a))
        }
        guard seconds >= -0.000001, hourlySeconds >= -0.000001 else { throw HistoryError.invalid }
        try run("DELETE FROM coverage_intervals WHERE day=? AND source=? AND start<=? AND end>=?",
                [day, source, String(high), String(low)])
        try run("INSERT INTO coverage_intervals VALUES (?,?,?,?)",
                [day, source, String(mergedLow), String(mergedHigh)])
        let dayDuration = clock.interval(.day, selected: start, now: start).duration
        try run("""
        INSERT INTO coverage(day,source,seconds) VALUES (?,?,?)
        ON CONFLICT(day,source) DO UPDATE SET seconds=max(seconds,min(seconds+excluded.seconds,CAST(? AS REAL)))
        """, [day, source, String(max(0, seconds)), String(dayDuration)])
        if high > hourlyLow {
            try run("""
            INSERT INTO hourly_usage(start,source,seconds) VALUES (?,?,?)
            ON CONFLICT(start,source) DO UPDATE SET seconds=max(seconds,min(seconds+excluded.seconds,CAST(? AS REAL)))
            """, [String(hour.start.timeIntervalSince1970), source, String(max(0, hourlySeconds)), String(hour.duration)])
        }
    }

    public func pruneHourlyHistory(now: Date) throws {
        try validateFiles()
        try Self.validateDate(now)
        let interval = clock.interval(.week, selected: now, now: now)
        try run("DELETE FROM hourly_usage WHERE start < ?", [String(interval.start.timeIntervalSince1970)])
    }

    public func hourlyTimeline(now: Date, source: UsageSource? = nil) throws -> UsageTimeline {
        try validateFiles()
        try pruneHourlyHistory(now: now)
        let intervals = clock.hours(on: now)
        let day = clock.interval(.today, selected: now, now: now)
        let s = try statement("""
        SELECT start,sum(tokens),sum(calls),max(CASE WHEN source=? THEN seconds ELSE 0 END),max(gap)
        FROM hourly_usage WHERE start>=? AND start<? \(source == nil ? "" : "AND source=?") GROUP BY start
        """, [source?.rawValue ?? "all", String(day.start.timeIntervalSince1970), String(day.end.timeIntervalSince1970)]
             + (source.map { [$0.rawValue] } ?? []))
        defer { sqlite3_finalize(s) }
        var values: [Date: UsageBucket] = [:]
        var total: Int64 = 0, calls: Int64 = 0
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryError.storage }
            let start = sqlite3_column_double(s, 0)
            guard start.isFinite else { throw HistoryError.invalid }
            let date = Date(timeIntervalSince1970: start)
            guard let interval = intervals.first(where: { $0.start == date }) else { throw HistoryError.invalid }
            var bucket = UsageBucket(interval: interval)
            bucket.tokens = sqlite3_column_int64(s, 1)
            bucket.calls = sqlite3_column_int64(s, 2)
            bucket.recordingSeconds = sqlite3_column_double(s, 3)
            let gap = sqlite3_column_int64(s, 4)
            let (nextTotal, tokenOverflow) = total.addingReportingOverflow(bucket.tokens)
            let (nextCalls, callOverflow) = calls.addingReportingOverflow(bucket.calls)
            guard sqlite3_column_type(s, 1) == SQLITE_INTEGER, sqlite3_column_type(s, 2) == SQLITE_INTEGER,
                  sqlite3_column_type(s, 4) == SQLITE_INTEGER, (0...1).contains(gap),
                  bucket.tokens >= 0, bucket.calls >= 0, !tokenOverflow, !callOverflow,
                  bucket.recordingSeconds.isFinite, (0...86_400_000).contains(bucket.recordingSeconds) else {
                throw HistoryError.invalid
            }
            total = nextTotal; calls = nextCalls
            bucket.gap = gap == 1 || interval.start < hourlyBegan
            values[date] = bucket
        }
        return UsageTimeline(granularity: .hour,
            buckets: intervals.map { values[$0.start] ?? UsageBucket(interval: $0) },
            zone: clock.calendar.timeZone.identifier, detailBegan: hourlyBegan)
    }

    public func query(_ interval: DateInterval, model: String? = nil,
                      source: UsageSource? = nil) throws -> HistorySnapshot {
        try validateFiles()
        try Self.validateDate(interval.start)
        try Self.validateDate(interval.end)
        guard clock.dayCount(interval) <= 366 else { throw HistoryError.invalid }
        let start = clock.key(interval.start), end = clock.key(interval.end)
        let sourceFilter = source == nil ? "" : " AND source=?"
        let values = [start, end] + (source.map { [$0.rawValue] } ?? [])
        var days: [String: HistoryDay] = [:]
        var models: [String: HistoryTotals] = [:]
        let s = try statement("""
        SELECT day,model,input,output,cache_input,calls,first_sum,first_count,duration_sum,duration_count,
          cache_reported_calls,cache_unreported_calls,cache_write,write_reported_calls,write_unreported_calls,accounting
        FROM usage WHERE day>=? AND day<? \(sourceFilter) ORDER BY day,model
        """, values)
        defer { sqlite3_finalize(s) }
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryError.storage }
            let day = try text(s, 0), name = try text(s, 1)
            var value = HistoryTotals()
            value.input = sqlite3_column_int64(s, 2); value.output = sqlite3_column_int64(s, 3)
            value.cacheInput = sqlite3_column_int64(s, 4); value.calls = sqlite3_column_int64(s, 5)
            value.firstTokenSum = sqlite3_column_double(s, 6)
            value.firstTokenSamples = sqlite3_column_int64(s, 7)
            value.durationSum = sqlite3_column_double(s, 8); value.durationSamples = sqlite3_column_int64(s, 9)
            value.cacheReportedCalls = sqlite3_column_int64(s, 10)
            value.cacheUnreportedCalls = sqlite3_column_int64(s, 11)
            value.cacheWrite = sqlite3_column_int64(s, 12)
            value.cacheWriteReportedCalls = sqlite3_column_int64(s, 13)
            value.cacheWriteUnreportedCalls = sqlite3_column_int64(s, 14)
            let accounting = sqlite3_column_int64(s, 15)
            value.unverifiedCalls = accounting == 0 ? value.calls : 0
            guard value.input >= 0, value.output >= 0, value.cacheInput >= 0, value.calls >= 0,
                  value.cacheCoverage.isValid, value.breakdown.write.isValid,
                  (0...1).contains(accounting),
                  [2, 3, 4, 5, 7, 9].allSatisfy({ sqlite3_column_type(s, Int32($0)) == SQLITE_INTEGER }),
                  (12...15).allSatisfy({ sqlite3_column_type(s, Int32($0)) == SQLITE_INTEGER }),
                  sqlite3_column_type(s, 10) == SQLITE_INTEGER, sqlite3_column_type(s, 11) == SQLITE_INTEGER,
                  (0...value.calls).contains(value.firstTokenSamples), (0...value.calls).contains(value.durationSamples),
                  value.firstTokenSum.isFinite, value.durationSum.isFinite else { throw HistoryError.invalid }
            try models[name, default: HistoryTotals()].add(value)
            if model == nil || model == name {
                if days[day] == nil { days[day] = HistoryDay(day: day) }
                try days[day]?.tokens.add(value)
            }
        }
        let c = try statement("""
        SELECT day,maximum,completed,failed,seen FROM context WHERE day>=? AND day<? \(sourceFilter)
        """, values)
        defer { sqlite3_finalize(c) }
        var completedTotal: Int64 = 0
        var failedTotal: Int64 = 0
        while true {
            let status = sqlite3_step(c)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryError.storage }
            let day = try text(c, 0)
            let maximum = sqlite3_column_double(c, 1)
            let completed = sqlite3_column_int64(c, 2), failed = sqlite3_column_int64(c, 3)
            let (nextCompleted, completedOverflow) = completedTotal.addingReportingOverflow(completed)
            let (nextFailed, failedOverflow) = failedTotal.addingReportingOverflow(failed)
            guard maximum.isFinite, maximum >= 0, completed >= 0, failed >= 0,
                  !completedOverflow, !failedOverflow else { throw HistoryError.invalid }
            completedTotal = nextCompleted; failedTotal = nextFailed
            if days[day] == nil { days[day] = HistoryDay(day: day) }
            if sqlite3_column_type(c, 1) != SQLITE_NULL {
                let mergedMaximum = max(days[day]?.contextMaximum ?? 0, maximum)
                days[day]?.hasContext = true
                days[day]?.contextMaximum = mergedMaximum
            }
            days[day]?.compactions += completed
            days[day]?.failedCompactions += failed
            if sqlite3_column_int64(c, 4) != 0 { days[day]?.hasCompaction = true }
        }
        let coverage = try statement("""
        SELECT day,seconds,gap,imported FROM coverage WHERE day>=? AND day<? AND source=?
        """, [start, end, source?.rawValue ?? "all"])
        defer { sqlite3_finalize(coverage) }
        while true {
            let status = sqlite3_step(coverage)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryError.storage }
            let day = try text(coverage, 0)
            let seconds = sqlite3_column_double(coverage, 1)
            guard seconds.isFinite, (0...86_400_000).contains(seconds) else { throw HistoryError.invalid }
            if days[day] == nil { days[day] = HistoryDay(day: day) }
            days[day]?.recordingSeconds = sqlite3_column_double(coverage, 1)
            days[day]?.gap = sqlite3_column_int(coverage, 2) != 0
            days[day]?.imported = sqlite3_column_int(coverage, 3) != 0
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("usage.sqlite").path)
        guard let bytes = (attributes[.size] as? NSNumber)?.int64Value else { throw HistoryError.storage }
        var totals = HistoryTotals()
        for day in days.values { try totals.add(day.tokens) }
        return HistorySnapshot(days: days.values.sorted { $0.day < $1.day },
            models: models.map { HistoryModel(id: $0.key, tokens: $0.value) }.sorted { $0.tokens.total > $1.tokens.total },
            zone: clock.calendar.timeZone.identifier, began: began,
            bytes: bytes, totals: totals, hasImportedData: days.values.contains(where: \.imported))
    }

    public func delete() throws {
        try validateFiles()
        if let database {
            guard sqlite3_close(database) == SQLITE_OK else { throw HistoryError.storage }
            self.database = nil
        }
        try Self.removeArchive(root: directory.deletingLastPathComponent())
    }

    public static func removeArchive(root: URL) throws {
        let directory = root.appendingPathComponent("history", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try PrivateFiles.directory(root)
        try PrivateFiles.directory(directory)
        try validateFiles(in: directory)
        for name in ["usage.sqlite", "usage.sqlite-journal", "usage.sqlite-wal", "usage.sqlite-shm"] {
            let path = directory.appendingPathComponent(name).path
            if unlink(path) != 0 && errno != ENOENT { throw HistoryError.storage }
        }
    }
}
