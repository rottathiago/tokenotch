import Foundation
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum ContextChecks {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let one = ActivityEvent.digest("one")
        let two = ActivityEvent.digest("two")
        func reading(_ count: Int64, limit: Int64 = 100, at offset: Double, session: String = one) -> ActivityEvent {
            ActivityEvent(source: .cli, session: session, kind: .context, timestamp: now.addingTimeInterval(offset),
                          context: ContextUsage(currentTokens: count, tokenLimit: limit))
        }
        func invalidation(at offset: Double, session: String = one) -> ActivityEvent {
            ActivityEvent(source: .cli, session: session, kind: .contextInvalidated,
                          timestamp: now.addingTimeInterval(offset), metricID: ActivityEvent.digest("reset-\(offset)"))
        }
        var ledger = TokenLedger()
        var insights = SessionInsights()
        var warnings = ContextWarningPolicy()
        var attention = SessionAttentionState()
        func feed(_ event: ActivityEvent) throws {
            try ledger.observe(event, now: event.timestamp)
            insights.observe(event, now: event.timestamp)
            _ = warnings.evaluate(event, now: event.timestamp)
            try attention.observe(event, now: event.timestamp)
        }
        try feed(reading(85, at: 0))
        try feed(reading(20, at: 0, session: two))
        let usage = ActivityEvent(source: .cli, session: one, kind: .usage, timestamp: now,
            tokens: TokenUsage(callID: ActivityEvent.digest("call"), input: 500, output: 100, model: "model-a"))
        try ledger.observe(usage, now: now)
        try feed(invalidation(at: 1))
        try HistoryChecks.require(ledger.bySession.first { $0.id == one }?.context == nil
                                  && insights.sessions.first { $0.id == one }?.context == nil,
                                  "A reset/model change clears both session stats and notch context")
        try HistoryChecks.require(ledger.bySession.first { $0.id == two }?.context?.usage.currentTokens == 20,
                                  "One session's reset must not reset another session")
        try HistoryChecks.require(ledger.totals?.total == 600 && ledger.byModel.first?.model == "model-a",
                                  "Context resets must not erase cumulative usage")
        try HistoryChecks.require(attention.notices.first { $0.kind == .context }?.disposition == .superseded,
                                  "An obsolete context window must not retain a high-context notice")
        try feed(reading(99, at: 0.5))
        try feed(reading(99, at: 1))
        try HistoryChecks.require(ledger.bySession.first { $0.id == one }?.context == nil
                                  && insights.sessions.first { $0.id == one }?.context == nil,
                                  "Older and equal-time readings cannot undo invalidation")
        try feed(reading(0, at: 2))
        try HistoryChecks.require(ledger.bySession.first { $0.id == one }?.context?.usage.fraction == 0,
                                  "A reported context clear is a real zero, not unavailable")
        try feed(reading(40, limit: 200, at: 3))
        try feed(invalidation(at: 1))
        try HistoryChecks.require(ledger.bySession.first { $0.id == one }?.context?.usage.fraction == 0.2
                                  && insights.sessions.first { $0.id == one }?.context?.usage.tokenLimit == 200,
                                  "Model changes replace the denominator; delayed invalidations are ignored")
        try feed(reading(15, limit: 200, at: 4))
        try HistoryChecks.require(ledger.bySession.first { $0.id == one }?.context?.usage.currentTokens == 15,
                                  "Compaction and rewind readings replace rather than accumulate tokens")
        try feed(reading(240, limit: 200, at: 5))
        let context = ledger.bySession.first { $0.id == one }?.context
        try HistoryChecks.require(context?.usage.fraction == 1.2 && context?.isStale(now: now.addingTimeInterval(305)) == false
                                  && context?.isStale(now: now.addingTimeInterval(306)) == true,
                                  "Preserve over-limit numbers and the exact freshness boundary")
        try HistoryChecks.require(ledger.filtered(.vscodeLocal).bySession.isEmpty,
                                  "CLI context cannot become VS Code context")
        var activity = ActivityState()
        try HistoryChecks.rejects("Context invalidation cannot become session activity") {
            _ = try activity.accept(invalidation(at: 6), now: now.addingTimeInterval(6))
        }
        try HistoryChecks.require(Notice.activity(invalidation(at: 6)) == nil,
                                  "Invalidation never means task completion")
        _ = warnings.evaluate(invalidation(at: 6), now: now.addingTimeInterval(6))
        try HistoryChecks.require(warnings.evaluate(reading(190, limit: 200, at: 7), now: now.addingTimeInterval(7)) == nil,
                                  "A new model's first reading is not a crossing from the old model")
        var bounded = TokenLedger()
        for index in 0..<101 {
            let event = invalidation(at: Double(index), session: ActivityEvent.digest("session-\(index)"))
            try bounded.observe(event, now: event.timestamp)
        }
        try HistoryChecks.require(bounded.bySession.count == 100, "Invalidation tombstones must be bounded")
        bounded.expire(now: now.addingTimeInterval(86_501))
        try HistoryChecks.require(bounded.bySession.isEmpty, "Invalidation tombstones must expire")
        ledger.remove(.cli)
        try HistoryChecks.require(ledger.bySession.isEmpty, "Disconnect clears context and tombstones")
        try normalization(now: now)
    }

    private static func normalization(now: Date) throws {
        let fields: [String: Any] = ["sessionId": "private-session", "timestamp": now.timeIntervalSince1970 * 1000,
                                     "eventId": "reset", "prompt": "private-prompt"]
        let event = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: fields),
            source: .cli, hook: "contextInvalidated", now: now)
        let data = try JSONEncoder().encode(event)
        try HistoryChecks.require(event.version == 2 && event.kind == .contextInvalidated && event.context == nil
                                  && event.tokens == nil && event.metricID != nil,
                                  "Invalidation is a CLI-only metric without fabricated tokens")
        try HistoryChecks.require(try JSONDecoder().decode(ActivityEvent.self, from: data) == event
                                  && !String(decoding: data, as: UTF8.self).contains("private"),
                                  "Invalidation must round-trip without content")
        for key in ["sessionId", "eventId", "timestamp"] {
            var invalid = fields
            invalid.removeValue(forKey: key)
            try HistoryChecks.rejects("Invalidation requires \(key)") {
                _ = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: invalid),
                    source: .cli, hook: "contextInvalidated", now: now)
            }
        }
        for key in ["currentTokens", "tokenLimit"] {
            let invalid = fields.merging([key: 0]) { _, value in value }
            try HistoryChecks.rejects("Invalidation cannot contain numeric readings") {
                _ = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: invalid),
                    source: .cli, hook: "contextInvalidated", now: now)
            }
        }
        try HistoryChecks.rejects("VS Code must not manufacture context invalidations") {
            try ActivityEvent(source: .vscode, session: event.session, kind: .contextInvalidated,
                              timestamp: now, metricID: event.metricID).validate(now: now)
        }
    }
}
