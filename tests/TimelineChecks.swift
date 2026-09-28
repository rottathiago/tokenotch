import Darwin
import Foundation
import TokenotchCore
import SQLite3

enum TimelineChecks {
    static let now = HistoryChecks.date("2026-09-21T12:00:00Z")
    static func event(_ id: Int, session: String = "private-session", date: Date = now,
                      model: String? = "model-a", source: Client = .cli) -> ActivityEvent {
        if source == .vscode {
            return ActivityEvent(source: source, session: ActivityEvent.digest(session), kind: .stopped, timestamp: date)
        }
        return ActivityEvent(source: source, session: ActivityEvent.digest(session), kind: .usage, timestamp: date,
            tokens: TokenUsage(callID: ActivityEvent.digest("\(session):\(id)"), input: 10, output: 2, model: model,
                               durationMs: 100, timeToFirstTokenMs: 0))
    }

    static func persistence() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: SessionTimelineStore? = try SessionTimelineStore(root: root, now: now)
        let hash = ActivityEvent.digest("private-session")
        let session = store!.sessionID(source: .cli, hash: hash)
        try HistoryChecks.require(session != hash, "Stable bridge session hash archived")
        let a = event(1, date: now.addingTimeInterval(-10))
        let b = event(2, date: now.addingTimeInterval(-5), model: "model-b")
        try store!.record([b, a, a, event(3, source: .vscode)], retention: .seven, now: now)
        var page = try store!.events(session: session)
        try HistoryChecks.require(page.events.count == 2 && page.events.first?.timestamp == a.timestamp,
                                  "Late event ordering or usage deduplication")
        try HistoryChecks.require(page.events[1].annotation(previous: page.events[0], timestampIsAmbiguous: false)?.contains("not an explicit") == true,
                                  "Model difference mislabeled")
        try HistoryChecks.require(page.events[1].annotation(previous: page.events[0], timestampIsAmbiguous: true) == nil,
                                  "Ambiguous ordering invented a transition")
        try HistoryChecks.require(try store!.status().sessionCount == 2, "Client namespaces merged")
        try store!.recording(true, now: now)
        store = nil
        store = try SessionTimelineStore(root: root, now: now.addingTimeInterval(1))
        try store!.record([a, b], retention: .seven, now: now)
        try HistoryChecks.require(try store!.status().eventCount == 3 && store!.status().interrupted,
                                  "Restart lost rows/deduplication/interruption")
        try HistoryChecks.require(store!.sessionID(source: .cli, hash: hash) == session, "Resume identity changed")
        let fields: [String: Any] = ["sessionId": "private-session", "eventId": "context",
            "timestamp": now.timeIntervalSince1970 * 1000, "currentTokens": 80, "tokenLimit": 100,
            "prompt": "private-prompt", "cwd": "/private-path", "error": "private-error"]
        let context = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: fields), source: .cli, hook: "context", now: now)
        try HistoryChecks.require(context.metricID != nil && context.version == 1, "Optional context identity not preserved")
        var legacyFields = fields
        legacyFields.removeValue(forKey: "eventId")
        let legacy = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: legacyFields), source: .cli, hook: "context", now: now)
        try HistoryChecks.require(legacy.metricID == nil, "Legacy context compatibility")
        try store!.record([context, context, legacy, legacy], retention: .seven, now: now)
        page = try store!.events(session: session)
        try HistoryChecks.require(page.events.count == 4, "Context identity/fallback deduplication")
        let compaction = ActivityEvent(source: .cli, session: hash, kind: .compaction, timestamp: now,
            compaction: CompactionUsage(success: false, before: 80, after: 20), metricID: ActivityEvent.digest("compaction"))
        try store!.record([compaction, compaction], retention: .seven, now: now)
        try HistoryChecks.require(try store!.events(session: session).events.last { $0.kind == .compaction }?.title == "Compaction failed",
                                  "Compaction must not become lifecycle failure")
        var info = stat()
        let file = root.appendingPathComponent("timeline/sessions.sqlite")
        try HistoryChecks.require(lstat(file.path, &info) == 0 && info.st_mode & 0o077 == 0, "Timeline file permissions")
        let data = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for forbidden in ["private-session", "private-prompt", "/private-path", "private-error", hash, a.tokens!.callID] {
            try HistoryChecks.require(!data.contains(forbidden), "Private fields or stable bridge identifiers persisted")
        }
        try store!.delete()
        store = nil
        let fresh = try SessionTimelineStore(root: root, now: now)
        try HistoryChecks.require(fresh.sessionID(source: .cli, hash: hash) != session, "Delete did not rotate archive identity")
        try HistoryChecks.require(try fresh.status().eventCount == 0, "Deleted events remained")
    }

    static func limits() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionTimelineStore(root: root, now: now)
        let session = store.sessionID(source: .cli, hash: ActivityEvent.digest("private-session"))
        try store.record((0..<2000).map { event($0, date: now.addingTimeInterval(Double($0) / 1000)) }, retention: .seven, now: now)
        try HistoryChecks.require(try store.status().eventCount == 2000 && !store.status().pruned, "Exact session limit truncated")
        try store.record([event(2000, date: now.addingTimeInterval(2)), event(0)], retention: .seven, now: now)
        try HistoryChecks.require(try store.status().eventCount == 2000 && store.sessions().first?.truncated == true,
                                  "Per-session boundary-plus-one not enforced")
        var collected: [TimelineEvent] = []
        var more = true
        while more {
            let page = try store.events(session: session, after: collected.last)
            try HistoryChecks.require(page.events.count <= 100, "Page exceeded 100")
            collected += page.events
            more = page.hasMore
        }
        try HistoryChecks.require(collected.count == 2000 && Set(collected.map(\.id)).count == 2000
                                  && collected.first?.timestamp == now.addingTimeInterval(0.001), "Pagination or oldest-first pruning")
        try store.record([event(0)], retention: .seven, now: now)
        try HistoryChecks.require(try store.events(session: session).events.first?.id == collected.first?.id,
                                  "Pruned event replay resurrected")
        try store.maintain(retention: .one, now: now.addingTimeInterval(86_402))
        try HistoryChecks.require(try store.status().eventCount == 1, "Retention exact cutoff must survive")
        try store.maintain(retention: .one, now: now.addingTimeInterval(86_403))
        try HistoryChecks.require(try store.status().sessionCount == 0, "Expired session identifier remains")
        try store.record((0..<1000).map { event($0, session: "session-\($0)", date: now.addingTimeInterval(Double($0))) },
                         retention: .seven, now: now.addingTimeInterval(1000))
        try HistoryChecks.require(try store.status().sessionCount == 1000, "Exact session-count limit")
        try store.record([event(1000, session: "session-1000", date: now.addingTimeInterval(1000))],
                         retention: .seven, now: now.addingTimeInterval(1000))
        try HistoryChecks.require(try store.status().sessionCount == 1000 && store.status().eventCount == 1000,
                                  "Session count boundary-plus-one")
        try store.delete()
        let global = try SessionTimelineStore(root: root, now: now)
        let many = (0..<100000).map { event($0, session: "group-\($0 % 100)", date: now.addingTimeInterval(Double($0) / 1000)) }
        try global.record(many, retention: .seven, now: now.addingTimeInterval(100))
        try HistoryChecks.require(try global.status().eventCount == 100000 && !global.status().pruned,
                                  "Exact global limit")
        try global.record([event(100000, session: "group-0", date: now.addingTimeInterval(100))],
                          retention: .seven, now: now.addingTimeInterval(100))
        try HistoryChecks.require(try global.status().eventCount == 100000 && global.status().pruned,
                                  "Global boundary-plus-one")
    }

    static func ordering() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionTimelineStore(root: root, now: now)
        let hash = ActivityEvent.digest("context-session")
        let session = store.sessionID(source: .cli, hash: hash)
        func context(_ tokens: Int64, _ offset: Double) -> ActivityEvent {
            ActivityEvent(source: .cli, session: hash, kind: .context,
                          timestamp: now.addingTimeInterval(offset),
                          context: ContextUsage(currentTokens: tokens, tokenLimit: 100))
        }
        let earlier = ActivityEvent(source: .cli, session: hash, kind: .started, timestamp: now.addingTimeInterval(-20))
        let later = ActivityEvent(source: .cli, session: hash, kind: .stopped, timestamp: now)
        var activity = ActivityState()
        _ = try activity.accept(later, now: now)
        try HistoryChecks.require(try !activity.accept(earlier, now: now), "Latest live state regressed")
        try store.record([later, earlier, context(80, -5), context(20, 0)], retention: .seven, now: now)
        let rows = try store.events(session: session).events
        let contexts = rows.filter { $0.kind == .context }
        try HistoryChecks.require(rows.contains { $0.kind == .started } && rows.contains { $0.kind == .stopped },
                                  "Timeline lost valid late lifecycle events")
        try HistoryChecks.require(contexts[1].annotation(previous: contexts[0], timestampIsAmbiguous: false)?.contains("-60") == true,
                                  "Context difference missing")
        try HistoryChecks.require(!rows.contains { $0.kind == .compaction }, "Context drop invented compaction")
        try store.record([context(30, 0)], retention: .seven, now: now)
        try HistoryChecks.require(try store.events(session: session).events.filter { $0.kind == .context }.count == 3,
                                  "Distinct legacy context values at the same timestamp merged")
        let unsupported = ActivityEvent(source: .vscode, session: hash, kind: .failed, timestamp: now)
        try HistoryChecks.rejects("Unsupported VS Code failure archived") {
            try store.record([unsupported], retention: .seven, now: now)
        }
        let calls = store.sessionID(source: .cli, hash: ActivityEvent.digest("private-session"))
        try store.record([event(1, date: now.addingTimeInterval(-2)),
                          event(2, date: now.addingTimeInterval(-1), model: nil),
                          event(3, date: now, model: "model-b")], retention: .seven, now: now)
        let samples = try store.events(session: calls).events
        try HistoryChecks.require(samples[2].annotation(previous: samples[1], timestampIsAmbiguous: false) == nil,
                                  "Unknown intervening model invented a transition")
        try store.delete()
        let tied = try SessionTimelineStore(root: root, now: now)
        try tied.record((0..<201).map { event($0) }, retention: .seven, now: now)
        let tiedSession = tied.sessionID(source: .cli, hash: ActivityEvent.digest("private-session"))
        let first = try tied.events(session: tiedSession)
        let second = try tied.events(session: tiedSession, after: first.events.last)
        let third = try tied.events(session: tiedSession, after: second.events.last)
        try HistoryChecks.require(first.events.count == 100 && second.events.count == 100 && third.events.count == 1
                                  && Set((first.events + second.events + third.events).map(\.id)).count == 201,
                                  "Same-time pagination skipped or duplicated rows")
    }

    static func failures() throws {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: SessionTimelineStore? = try SessionTimelineStore(root: root, now: now)
        try store!.record([event(1)], retention: .seven, now: now)
        store = nil
        let file = root.appendingPathComponent("timeline/sessions.sqlite")
        var db: OpaquePointer?
        try HistoryChecks.require(sqlite3_open(file.path, &db) == SQLITE_OK, "Fixture open")
        try HistoryChecks.require(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil) == SQLITE_OK, "Fixture schema")
        sqlite3_close(db)
        try HistoryChecks.rejects("Future schema replaced") { _ = try SessionTimelineStore(root: root) }
        try SessionTimelineStore.removeArchive(root: root)
        try PrivateFiles.write(Data("corrupt".utf8), to: file)
        try HistoryChecks.rejects("Corrupt archive became empty") { _ = try SessionTimelineStore(root: root) }
        try SessionTimelineStore.removeArchive(root: root)
        let unrelated = root.appendingPathComponent("untouched")
        try PrivateFiles.write(Data("private".utf8), to: unrelated)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: unrelated)
        try HistoryChecks.rejects("Unsafe archive followed") { _ = try SessionTimelineStore(root: root) }
        try HistoryChecks.rejects("Unsafe archive deleted") { try SessionTimelineStore.removeArchive(root: root) }
        try HistoryChecks.require(try String(contentsOf: unrelated, encoding: .utf8) == "private", "Unrelated file changed")
    }
}
