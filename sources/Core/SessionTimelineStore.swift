import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Confine this store to its controller's serial queue.
public final class SessionTimelineStore {
    private var database: OpaquePointer?
    private let directory: URL
    private var key: SymmetricKey
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL, now: Date = Date()) throws {
        directory = root.appendingPathComponent("timeline", isDirectory: true)
        key = SymmetricKey(size: .bits256)
        try PrivateFiles.directory(root)
        try PrivateFiles.directory(directory)
        try Self.validateFiles(directory)
        let file = directory.appendingPathComponent("sessions.sqlite")
        if !FileManager.default.fileExists(atPath: file.path) { try PrivateFiles.write(Data(), to: file) }
        guard let canonical = realpath(directory.path, nil) else { throw TokenotchError.unsafePath }
        let path = String(cString: canonical) + "/sessions.sqlite"
        free(canonical)
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw TimelineError.storage
        }
        do {
            sqlite3_busy_timeout(database, 1000)
            let version = try integer("PRAGMA user_version")
            guard version <= 3 else { throw TimelineError.schema }
            guard version >= 0 else { throw TimelineError.invalid }
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL")
            if version == 0 {
                try transaction {
                    try execute("""
                    CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE sessions(id TEXT PRIMARY KEY, source TEXT NOT NULL, truncated INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE events(id TEXT PRIMARY KEY, session TEXT NOT NULL, time REAL NOT NULL, payload TEXT NOT NULL);
                    CREATE INDEX events_session_time ON events(session,time,id);
                    CREATE INDEX events_time ON events(time,id);
                    CREATE TABLE receipts(id TEXT PRIMARY KEY, time REAL NOT NULL);
                    CREATE INDEX receipts_time ON receipts(time);
                    PRAGMA user_version=1;
                    """)
                    try set("key", key.withUnsafeBytes { Data($0).base64EncodedString() })
                    try set("active", "0")
                }
            }
            if version < 2 {
                // Legacy JSON stays untouched: absence of an accounting marker is meaningful.
                try transaction { try execute("PRAGMA user_version=2") }
            }
            if version < 3 { try transaction { try execute("PRAGMA user_version=3") } }
            guard let encoded = try get("key"), let data = Data(base64Encoded: encoded), data.count == 32 else {
                throw TimelineError.invalid
            }
            key = SymmetricKey(data: data)
            if try get("active") == "1" { try set("interrupted", "1") }
            try set("active", "0")
            try pruneReceipts(now: now)
            try Self.validateFiles(directory)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    private static func validateFiles(_ directory: URL) throws {
        for name in ["sessions.sqlite", "sessions.sqlite-journal", "sessions.sqlite-wal", "sessions.sqlite-shm"] {
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
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TimelineError.storage }
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw TimelineError.storage
        }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(result, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(result)
                throw TimelineError.storage
            }
        }
        return result
    }
    private func run(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw TimelineError.storage }
    }
    private func integer(_ sql: String, _ values: [String] = []) throws -> Int64 {
        let s = try statement(sql, values)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw TimelineError.storage }
        return sqlite3_column_int64(s, 0)
    }
    private func text(_ s: OpaquePointer, _ column: Int32) throws -> String {
        guard let value = sqlite3_column_text(s, column) else { throw TimelineError.invalid }
        return String(cString: value)
    }
    private func get(_ name: String) throws -> String? {
        let s = try statement("SELECT value FROM metadata WHERE key=?", [name])
        defer { sqlite3_finalize(s) }
        let result = sqlite3_step(s)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw TimelineError.storage }
        return try text(s, 0)
    }
    private func set(_ name: String, _ value: String) throws {
        try run("INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [name, value])
    }
    private func transaction(_ body: () throws -> Void) throws {
        try Self.validateFiles(directory)
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch {
            guard sqlite3_exec(database, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw TimelineError.storage }
            throw error
        }
    }
    private func pseudonym(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }
    public func sessionID(source: Client, hash: String) -> String {
        pseudonym("session:\(source.rawValue):\(hash)")
    }

    private func pruneReceipts(now: Date) throws {
        try run("DELETE FROM receipts WHERE time<? OR time>?",
                [String(now.addingTimeInterval(-600).timeIntervalSince1970), String(now.addingTimeInterval(30).timeIntervalSince1970)])
        try execute("DELETE FROM receipts WHERE id IN (SELECT id FROM receipts ORDER BY time DESC,id DESC LIMIT -1 OFFSET 18000)")
    }

    public func record(_ events: [ActivityEvent], retention: TimelineRetention, now: Date = Date()) throws {
        try transaction {
            for event in events {
                try event.validate(now: event.timestamp)
                guard !event.kind.isActivitySnapshot, !event.kind.isAttention, event.kind != .contextInvalidated else { continue }
                guard event.timestamp >= now.addingTimeInterval(-Double(retention.rawValue) * 86_400) else { continue }
                let session = sessionID(source: event.source, hash: event.session)
                let fallback = "\(event.id):\(event.context?.currentTokens.description ?? ""):\(event.context?.tokenLimit.description ?? "")"
                let id = pseudonym("event:\(event.source.rawValue):\(event.session):\(event.kind.rawValue):\(event.tokens?.callID ?? event.metricID ?? fallback)")
                try run("INSERT OR IGNORE INTO receipts VALUES (?,?)", [id, String(now.timeIntervalSince1970)])
                guard sqlite3_changes(database) != 0 else { continue }
                let value = TimelineEvent(id: id, session: session, source: event.source,
                    timestamp: event.timestamp, kind: event.kind, model: event.tokens?.model,
                    input: event.tokens?.input, output: event.tokens?.output, cacheInput: event.tokens?.cacheInput,
                    firstTokenMs: event.tokens?.timeToFirstTokenMs, durationMs: event.tokens?.durationMs,
                    contextTokens: event.context?.currentTokens, contextLimit: event.context?.tokenLimit,
                    compactionSuccess: event.compaction?.success, before: event.compaction?.before, after: event.compaction?.after,
                    cacheInputReported: event.tokens?.cacheInputReported,
                    cacheWrite: event.tokens?.cacheWrite, cacheWriteReported: event.tokens?.cacheWriteReported,
                    accountingVersion: event.tokens?.accountingVersion, metricSource: event.metricSource)
                try value.validate()
                let payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                try run("INSERT OR IGNORE INTO sessions(id,source) VALUES (?,?)", [session, event.source.rawValue])
                try run("INSERT OR IGNORE INTO events VALUES (?,?,?,?)",
                        [id, session, String(event.timestamp.timeIntervalSince1970), payload])
            }
            try prune(retention: retention, now: now)
        }
    }

    private func discard(_ selection: String, values: [String] = []) throws {
        try run("UPDATE sessions SET truncated=1 WHERE id IN (SELECT session FROM events WHERE id IN (\(selection)))", values)
        try run("DELETE FROM events WHERE id IN (\(selection))", values)
        if sqlite3_changes(database) > 0 { try set("pruned", "1") }
    }
    private func prune(retention: TimelineRetention, now: Date) throws {
        try discard("SELECT id FROM events WHERE time<?",
                    values: [String(now.addingTimeInterval(-Double(retention.rawValue) * 86_400).timeIntervalSince1970)])
        try discard("""
            SELECT id FROM (SELECT id,row_number() OVER (PARTITION BY session ORDER BY time DESC,id DESC) AS position FROM events)
            WHERE position>2000
            """)
        try discard("SELECT id FROM events ORDER BY time DESC,id DESC LIMIT -1 OFFSET 100000")
        try discard("""
            SELECT id FROM events WHERE session IN
            (SELECT session FROM events GROUP BY session ORDER BY max(time) DESC,session DESC LIMIT -1 OFFSET 1000)
            """)
        try execute("DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session FROM events)")
        try pruneReceipts(now: now)
    }
    public func maintain(retention: TimelineRetention, now: Date = Date()) throws {
        try transaction { try prune(retention: retention, now: now) }
    }
    public func recording(_ active: Bool, interrupted: Bool = false, now: Date = Date()) throws {
        try transaction {
            if interrupted { try set("interrupted", "1") }
            try set("active", active ? "1" : "0")
            try set("heartbeat", String(now.timeIntervalSince1970))
        }
    }
    public func heartbeat(now: Date) throws {
        let last = try get("heartbeat").flatMap(Double.init)
        let gap = last.map { now.timeIntervalSince1970 - $0 > 65 || now.timeIntervalSince1970 < $0 } ?? false
        try recording(true, interrupted: gap, now: now)
    }
    public func status() throws -> TimelineStatus {
        try TimelineStatus(sessionCount: Int(integer("SELECT count(*) FROM sessions")),
            eventCount: Int(integer("SELECT count(*) FROM events")),
            pruned: get("pruned") == "1", interrupted: get("interrupted") == "1")
    }
    public func sessions(offset: Int = 0) throws -> [TimelineSession] {
        guard offset >= 0, offset <= 1000 else { throw TimelineError.invalid }
        let s = try statement("""
            SELECT s.id,s.source,min(e.time),max(e.time),count(*),s.truncated
            FROM sessions s JOIN events e ON e.session=s.id GROUP BY s.id
            ORDER BY max(e.time) DESC,s.id DESC LIMIT 100 OFFSET ?
            """, [String(offset)])
        defer { sqlite3_finalize(s) }
        var result: [TimelineSession] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let source = try Client(rawValue: text(s, 1)) else { throw TimelineError.invalid }
            result.append(try TimelineSession(id: text(s, 0), source: source,
                first: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                last: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                count: Int(sqlite3_column_int64(s, 4)), truncated: sqlite3_column_int(s, 5) != 0))
        }
        return result
    }
    public func events(session: String, after: TimelineEvent? = nil) throws -> TimelinePage {
        let clause = after == nil ? "" : " AND (time>? OR (time=? AND id>?))"
        var values = [session]
        if let after {
            values += [String(after.timestamp.timeIntervalSince1970), String(after.timestamp.timeIntervalSince1970), after.id]
        }
        let s = try statement("SELECT payload FROM events WHERE session=?\(clause) ORDER BY time,id LIMIT 101", values)
        defer { sqlite3_finalize(s) }
        var result: [TimelineEvent] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw TimelineError.storage }
            let value = try JSONDecoder().decode(TimelineEvent.self, from: Data(text(s, 0).utf8))
            guard value.session == session else { throw TimelineError.invalid }
            try value.validate()
            result.append(value)
        }
        return TimelinePage(events: Array(result.prefix(100)), hasMore: result.count > 100)
    }

    public func delete() throws {
        try Self.validateFiles(directory)
        guard sqlite3_close(database) == SQLITE_OK else { throw TimelineError.storage }
        database = nil
        try Self.removeArchive(root: directory.deletingLastPathComponent())
    }
    public static func removeArchive(root: URL) throws {
        let directory = root.appendingPathComponent("timeline", isDirectory: true)
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw TokenotchError.unsafePath }
            return
        }
        try PrivateFiles.directory(directory)
        try validateFiles(directory)
        for name in ["sessions.sqlite-journal", "sessions.sqlite-wal", "sessions.sqlite-shm", "sessions.sqlite"] {
            if unlink(directory.appendingPathComponent(name).path) != 0, errno != ENOENT { throw TimelineError.storage }
        }
    }
}
