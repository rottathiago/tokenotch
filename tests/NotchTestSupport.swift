import AppKit
import TokenotchCore
import SQLite3
import SwiftUI
import Vision
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

enum NotchCheckFailure: Error {
    case failed(String)
}

@MainActor
enum NotchChecks {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NotchCheckFailure.failed(message) }
    }

    static func waitUntil(_ condition: () -> Bool) throws {
        for _ in 0..<200 {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        throw NotchCheckFailure.failed("Native fixture state did not settle")
    }

    static func click(_ panel: NSWindow, at point: CGPoint) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw NotchCheckFailure.failed("Could not create a fixture mouse event")
            }
            return event
        }
        let down = try event(.leftMouseDown)
        let up = try event(.leftMouseUp)
        // AppKit controls can synchronously track until mouse-up inside sendEvent.
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let pending = panel.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(pending)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    static func account(used: Double = 73, unlimited: Bool = false, longCopy: Bool = false) throws -> CopilotAccountSnapshot {
        let identity = try JSONSerialization.data(withJSONObject: [
            "isAuthenticated": true, "login": longCopy ? String(repeating: "account-", count: 12) : "fixture"
        ])
        let quota = try JSONSerialization.data(withJSONObject: ["quotaSnapshots": [
            longCopy ? String(repeating: "quota_", count: 10) : "premium_interactions": [
                "isUnlimitedEntitlement": unlimited, "entitlementRequests": 300,
                "usedRequests": used * 3, "remainingPercentage": 100 - used,
                "resetDate": "2027-01-16T08:00:00Z"
            ]
        ]])
        return try CopilotAccountSnapshot.parse(identity: identity, quota: quota, version: "fixture", now: now)
    }

    static func fixture(sessionCount: Int = 1, longCopy: Bool = false) throws -> NotchPresentation {
        var activity = ActivityState()
        var attention = SessionAttentionState()
        let kinds: [EventKind] = [.working, .stopped, .failed, .ended, .cancelled, .started]
        for index in 0..<sessionCount {
            let date = now.addingTimeInterval(index == 0 ? 0 : -Double(index * 60))
            let event = ActivityEvent(source: index.isMultiple(of: 2) ? .cli : .vscode,
                                      session: ActivityEvent.digest("fixture-\(index)"),
                                      kind: kinds[index % kinds.count], timestamp: date)
            _ = try activity.accept(event, now: date)
            try attention.observe(event, now: date)
        }
        var ledger = TokenLedger()
        try ledger.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("fixture"),
            kind: .usage, timestamp: now,
            tokens: TokenUsage(callID: ActivityEvent.digest("call"), input: longCopy ? 1_000_000_000 : 50_000,
                              output: 1_200, cacheInput: 40_000, cacheInputReported: true,
                              model: longCopy ? String(repeating: "model-", count: 21) : "fixture-model-a",
                              cacheWrite: 5_000, cacheWriteReported: true)),
                           now: now)
        for index in 1...3 {
            try ledger.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("fixture"),
                kind: .usage, timestamp: now, tokens: TokenUsage(callID: ActivityEvent.digest("extra-\(index)"),
                    input: Int64(12_000 / index), output: 100, model: index == 3 ? nil : "fixture-model-\(index)")),
                now: now)
        }
        var insights = SessionInsights()
        let insightSession = ActivityEvent.digest("fixture")
        insights.observe(ActivityEvent(source: .cli, session: insightSession, kind: .context, timestamp: now,
            context: ContextUsage(currentTokens: 85_000, tokenLimit: 100_000)), now: now)
        insights.observe(ActivityEvent(source: .cli, session: insightSession, kind: .usage, timestamp: now,
            tokens: TokenUsage(callID: ActivityEvent.digest("latency"), input: 10, output: 2,
                               durationMs: 2500, timeToFirstTokenMs: 120)), now: now)
        insights.observe(ActivityEvent(source: .cli, session: insightSession, kind: .compaction, timestamp: now,
            compaction: CompactionUsage(success: true, before: 90_000, after: 20_000),
            metricID: ActivityEvent.digest("compaction")), now: now)
        var result = NotchPresentation(account: try account(longCopy: longCopy), tokens: ledger.totals,
            tokensPartial: longCopy, sessions: activity.sessions.values.sorted { $0.id < $1.id },
            now: now,
            models: ledger.byModel, insights: insights.sessions)
        result.liveTimeline = ledger.hourlyTimeline(now: now)
        applyAttention(attention, to: &result)
        return result
    }

    static func applyAttention(_ state: SessionAttentionState, to data: inout NotchPresentation) {
        data.sessionNotices = state.notices
        data.noticeSessionIDs = Dictionary(uniqueKeysWithValues: data.sessions.map {
            ($0.id, state.sessionID(source: $0.source, hash: $0.key))
        })
    }

    static func modelUsageEvents(at date: Date) -> [ActivityEvent] {
        let models: [(String, Int64)] = [
            ("model-a", 600), ("model-b", 500), ("model-c", 400), ("claude-opus-5", 300),
            ("model-zero-b", 0), ("model-zero-a", 0)
        ]
        return models.map { model, tokens in
            ActivityEvent(source: .cli, session: ActivityEvent.digest("model-disclosure"), kind: .usage,
                timestamp: date, tokens: TokenUsage(callID: ActivityEvent.digest("\(date)-\(model)"),
                    input: tokens, output: 0, model: model))
        }
    }

    static func cacheFixtures() throws -> [(String, NotchPresentation, String, [ActivityEvent])] {
        let states: [(String, [(Int64?, Bool?)], String)] = [
            ("reported", [(12_000, true)], "12K"),
            ("zero", [(0, true)], "0"),
            ("not-reported", [(nil, false)], "n/r"),
            ("unknown", [(0, nil)], "?"),
            ("legacy-positive", [(9_000, nil)], "9K*"),
            ("partial", [(12_000, true), (nil, false)], "12K*"),
            ("partial-zero", [(0, true), (nil, false)], "0*")
        ]
        return try states.map { name, values, expected in
            var ledger = TokenLedger()
            var events: [ActivityEvent] = []
            for (index, value) in values.enumerated() {
                var fields: [String: Any] = ["usageContract": 1, "sessionId": "cache-render", "eventId": "\(name)-\(index)",
                    "timestamp": now.timeIntervalSince1970 * 1000, "inputTokens": 50_000, "outputTokens": 1_200,
                    "model": "cache-model"]
                if let count = value.0 {
                    fields["cacheReadTokens"] = count
                    fields["cacheWriteTokens"] = count
                }
                if let reported = value.1 {
                    fields["cacheReadTokensReported"] = reported
                    fields["cacheWriteTokensReported"] = reported
                }
                let event = try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: fields),
                    source: .cli, hook: "usage", now: now)
                try ledger.observe(event, now: now)
                events.append(event)
            }
            return (name, NotchPresentation(tokens: ledger.totals, now: now, models: ledger.byModel), expected, events)
        }
    }

    static func cachePresentation() throws {
        for (name, live, expected, events) in try cacheFixtures() {
            guard let liveTotals = live.usageTotals, let row = live.modelRows.first else {
                throw NotchCheckFailure.failed("Cache fixture missing")
            }
            try require(liveTotals.cacheCoverage.displayValue(compact: true) == expected
                        && row.cacheCoverage == liveTotals.cacheCoverage, "Live cache state \(name)")
            try require(liveTotals.breakdown.write.displayValue(compact: true) == expected
                        && row.breakdown == liveTotals.breakdown, "Live writes or classification \(name)")
            try require(liveTotals.total == Int64(events.count) * 51_200, "Live total includes caches twice")
            try require(!liveTotals.breakdown.totalDetails.contains("not a complete token total"),
                        "Missing cache classification must not imply missing total tokens")
            try require(!liveTotals.cacheCoverage.details.contains("*"), "Accessibility must explain a partial value")
            if !liveTotals.cacheCoverage.hasValue {
                try require(!liveTotals.cacheCoverage.details.hasPrefix("0 cached"), "Unknown announced as zero")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-cache-notch-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try UsageHistoryStore(root: root, now: now)
            try store.record(events, now: now)
            for range in [HistoryRange.today, .week] {
                let saved = try store.query(store.clock.interval(range, selected: now, now: now))
                let data = NotchPresentation(now: now, range: range, savedUsage: saved)
                try require(data.usageTotals?.cacheCoverage == liveTotals.cacheCoverage
                            && data.modelRows.first?.cacheCoverage.displayValue(compact: true) == expected,
                            "Saved cache state differs from live in \(range)")
                try require(data.usageTotals?.breakdown == liveTotals.breakdown
                            && data.modelRows.first?.breakdown == liveTotals.breakdown
                            && data.usageTotals?.total == liveTotals.total, "Saved write breakdown differs")
            }
        }
        var ledger = TokenLedger()
        for index in 0..<6 {
            let reported: Bool? = index == 4 ? false : index == 5 ? nil : true
            try ledger.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("residual"),
                kind: .usage, timestamp: now,
                tokens: TokenUsage(callID: ActivityEvent.digest("cache-residual-\(index)"),
                    input: Int64(60 - index), output: 2, cacheInputReported: reported,
                    model: index == 5 ? nil : "model-\(index)",
                    cacheWrite: reported == false ? 0 : 10, cacheWriteReported: reported)), now: now)
        }
        var data = NotchPresentation(tokens: ledger.totals, now: now, models: ledger.byModel)
        for expanded in [false, true, false] {
            data.modelsExpanded = expanded
            try require(data.modelRows.reduce(0) { $0 + $1.cacheReportedCalls } == 4
                        && data.modelRows.reduce(0) { $0 + $1.cacheUnreportedCalls } == 1
                        && data.modelRows.reduce(0) { $0 + $1.cacheCoverage.unknownCalls } == 1,
                        "Model disclosure changed reporting coverage")
            try require(data.modelRows.last?.cacheCoverage.isIncomplete == true, "Residual lost uncertainty")
            try require(data.modelRows.reduce(0) { $0 + $1.cacheWrite } == 50
                        && data.modelRows.reduce(0) { $0 + $1.cacheWriteReportedCalls } == 4
                        && data.modelRows.reduce(0) { $0 + $1.cacheWriteUnreportedCalls } == 1
                        && data.modelRows.reduce(0) { $0 + $1.breakdown.write.unknownCalls } == 1,
                        "Residual lost write counts or coverage")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-legacy-notch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, now: now)
        let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("legacy"), kind: .usage, timestamp: now,
            tokens: TokenUsage(callID: ActivityEvent.digest("legacy-call"), input: 1200, output: 45,
                               cacheInput: 900, model: "legacy"))
        try store.record([event], now: now)
        var db: OpaquePointer?
        try require(sqlite3_open(root.appendingPathComponent("history/usage.sqlite").path, &db) == SQLITE_OK,
                    "Open legacy presentation fixture")
        let result = sqlite3_exec(db, "UPDATE usage SET accounting=0", nil, nil, nil)
        sqlite3_close(db)
        try require(result == SQLITE_OK, "Set legacy accounting fixture")
        let snapshot = try store.query(store.clock.interval(.today, selected: now, now: now))
        let saved = NotchPresentation(now: now, savedUsage: snapshot)
        try require(saved.modelRows.first?.unverifiedCalls == 1
                    && saved.usageTotals?.breakdown.totalDetails.contains("input and cache may overlap") == true
                    && snapshot.totals.breakdown.inputLabel == "Input (breakdown incomplete)"
                    && !snapshot.totals.breakdown.inlineDetails.contains("legacy calls")
                    && !snapshot.totals.breakdown.inlineDetails.contains("unverified"),
                    "Legacy stats must keep accounting details in tooltips, not inline warnings")
        let completeLegacy = TokenBreakdown(
            read: CacheInputCoverage(tokens: 0, calls: 1, reportedCalls: 1, unreportedCalls: 0),
            write: CacheInputCoverage(tokens: 0, calls: 1, reportedCalls: 1, unreportedCalls: 0, kind: .write),
            unverifiedCalls: 1)
        try require(completeLegacy.inputLabel == "Input"
                    && !completeLegacy.inlineDetails.contains("legacy calls")
                    && completeLegacy.details.contains("input and cache may overlap"),
                    "Legacy provenance alone must not add an input warning")
    }

    static func layout() throws {
        try require(abs(NotchLayout.ringDiameter - 44) < 0.0001, "Reference ring must be 44pt")
        try require(abs(NotchLayout.cardWidth - 320) < 0.1, "Readable compact card width")
        try require(NotchLayout.trackStroke > NotchLayout.progressStroke, "Track must surround thin progress arc")
        try require(NotchLayout.scale(.nan) == 1 && NotchLayout.scale(3) == 1.5, "Scale bounds")
        for edge in NotchEdge.allCases {
            for scale in [0.75, 1, 1.5] {
                let size = NotchLayout.size(edge: edge, scale: scale)
                let center = NotchLayout.ringCenter(in: size, edge: edge, scale: scale)
                let ring = CGRect(x: center.x - 22 * scale, y: center.y - 22 * scale,
                                  width: 44 * scale, height: 44 * scale)
                let labelBottom = ring.maxY + (NotchLayout.ringLabelGap + NotchLayout.labelHeight) * scale
                let bounds = CGRect(origin: .zero, size: size)
                try require(bounds.contains(ring) && labelBottom < size.height, "Cell fits \(edge) at \(scale)")
                let shape = SideNotchShape(edge: edge, curlRadius: NotchLayout.curlRadius * scale,
                                           cornerRadius: NotchLayout.cornerRadius * scale).path(in: bounds)
                for x in [ring.minX, ring.maxX] {
                    for y in [ring.minY, labelBottom] {
                        try require(shape.contains(CGPoint(x: x, y: y)), "Ring/label must be inside black chrome")
                    }
                }
                let pill = NotchLayout.badgeRect(in: bounds, edge: edge, scale: scale, collapsed: true)
                try require(bounds.contains(pill), "Idle indicator fits \(edge) at \(scale)")
                try require(abs((edge.isVertical ? pill.width : pill.height) - NotchLayout.pillWidth * scale) < 0.001,
                            "Idle indicator has only the compact depth")
                try require(abs((edge.isVertical ? pill.height : pill.width) - NotchLayout.pillHeight * scale) < 0.001,
                            "Idle indicator has only the compact length")
                switch edge {
                case .right: try require(pill.maxX == bounds.maxX, "Right indicator touches bezel")
                case .left: try require(pill.minX == bounds.minX, "Left indicator touches bezel")
                case .top: try require(pill.minY == bounds.minY, "Top indicator touches bezel")
                case .bottom: try require(pill.maxY == bounds.maxY, "Bottom indicator touches bezel")
                }
                try require(NotchLayout.badgeRect(in: bounds, edge: edge, scale: scale, collapsed: false) == bounds,
                            "Disabling collapse preserves the full badge")
            }
        }
    }

    static func geometry() throws {
        struct Screen: ScreenDescribing {
            let frameValue: CGRect
            let visibleFrameValue: CGRect
        }
        for frame in [CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                      CGRect(x: 0, y: 0, width: 800, height: 600),
                      CGRect(x: 0, y: 0, width: 400, height: 340)] {
            let screen = Screen(frameValue: frame, visibleFrameValue: frame.insetBy(dx: 12, dy: 30))
            for edge in NotchEdge.allCases {
                for scale in [0.75, 1, 1.5] {
                    for offset: CGFloat in [-10000, 0, 10000] {
                        let notch = NotchGeometry.panelFrame(for: screen,
                            panelSize: NotchLayout.size(edge: edge, scale: scale), edge: edge, alongOffset: offset)
                        let local = NotchLayout.ringCenter(in: notch.size, edge: edge, scale: scale)
                        let center = CGPoint(x: notch.minX + local.x, y: notch.maxY - local.y)
                        for height: CGFloat in [240, 3000] {
                            let placement = NotchCardPlacement(notch: notch, ringCenter: center, edge: edge,
                                visibleFrame: screen.visibleFrameValue, contentHeight: height)
                            try require(screen.visibleFrameValue.contains(placement.frame), "Card remains on screen")
                            try require(!placement.frame.intersects(notch), "Card must not cover its ring")
                            let outline = placement.shape.path(in: placement.bounds)
                            try require(outline.contains(CGPoint(x: placement.bodyRect.midX, y: placement.bodyRect.midY)),
                                        "Card center painted")
                            try require(!outline.contains(CGPoint(x: placement.bodyRect.minX + 1,
                                                                 y: placement.bodyRect.minY + 1)),
                                        "Card corner must be transparent")
                            let tip = placement.shape.tip(in: placement.bounds)
                            let offsetLimit = (edge.isVertical ? placement.bodyRect.height : placement.bodyRect.width) / 2
                                - NotchLayout.cardCorner - NotchLayout.tailHeight / 2
                            try require(abs(placement.shape.clampedOffset(in: placement.bounds)) <= max(0, offsetLimit),
                                        "Tail must stay out of rounded corners")
                            let globalTip = CGPoint(x: placement.frame.minX + tip.x, y: placement.frame.maxY - tip.y)
                            try require(placement.hoverBridge.contains(globalTip), "Crossing corridor includes tip")
                            if offset == 0 {
                                let error = edge.isVertical ? abs(globalTip.y - center.y) : abs(globalTip.x - center.x)
                                try require(error < 0.01, "Unclamped pointer must aim at ring center")
                            }
                        }
                    }
                }
            }
        }
    }

    static func presentation() throws {
        for used in [0.0, 79, 80, 99, 100] {
            let snapshot = try account(used: used)
            let reading = CopilotRingReading(quota: snapshot.quotas.first, isStale: false, isWorking: false)
            try require(abs((reading.fraction ?? -1) - used / 100) < 0.0001, "True quota fraction")
            try require(reading.label == "\(Int(used))%", "Percentage is used, not remaining")
        }
        let missing = CopilotRingReading(quota: nil, isStale: false, isWorking: false)
        try require(missing.fraction == nil && missing.label != "0%", "Missing quota is not zero")
        let unlimited = CopilotRingReading(quota: try account(unlimited: true).quotas.first,
                                          isStale: false, isWorking: false)
        try require(unlimited.fraction == nil && unlimited.accessibilityValue.contains("Unlimited"), "Unlimited quota")
        let stale = CopilotRingReading(quota: try account().quotas.first, isStale: true, isWorking: true)
        try require(stale.accessibilityValue.contains("stale") && stale.accessibilityValue.contains("working"),
                    "Account staleness must not hide local activity")
        let attention = CopilotRingReading(quota: nil, isStale: false, isWorking: true, needsAttention: true)
        try require(attention.accessibilityValue.contains("attention") && attention.accessibilityValue.contains("working"),
                    "Collapsed attention must retain working semantics")
        let data = try fixture(sessionCount: 8, longCopy: true)
        try require((data.tokens?.input ?? 0) >= 1_000_000_000 && data.tokensPartial, "Keep large/partial token readings")
        try require(data.modelRows.first?.cacheInput == 40_000, "Model cache breakdown missing")
        try require(data.modelRows.first?.cacheWrite == 5_000, "Model write breakdown missing")
        try require(data.sessions.contains { $0.label(now: now) == "Execution stopped" }, "Stopped is not task success")
        try require(data.sessions.contains { $0.label(now: now) == "No recent activity updates" }, "Stale session truth")
        try require(data.insights.first?.latency?.timeToFirstTokenMs == 120, "Latency survives presentation")
        try require(data.insights.first?.compactionLabel(now: now) == "Compaction completed", "Compaction presentation")
        try redesign()
        try liveActivity()
        try cachePresentation()
        try usageFooter()
    }

    static func usageFooter() throws {
        var live = NotchPresentation(now: now)
        try require(live.provenance == "Live usage only; not saved", "Live usage must not claim to be saved")
        try require(live.sourceDetails.contains("Partial local usage coverage.")
                    && live.sourceDetails.contains("Restart clears live data."),
                    "Live coverage and retention remain available in the tooltip")
        live.tokensPartial = true
        try require(live.provenance == "Live only; sample limit reached", "Sample-limit warning remains visible")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-footer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, now: now)
        try store.record(modelUsageEvents(at: now), now: now)
        for hasGap in [false, true] {
            if hasGap { try store.markGap(at: now) }
            for range in [HistoryRange.today, .week] {
                let saved = try store.query(store.clock.interval(range, selected: now, now: now))
                var data = NotchPresentation(now: now, range: range, savedUsage: saved, historyRecording: true)
                try require(data.provenance == "Usage data saved locally", "Saved footer stays concise across periods and gaps")
                try require(data.sourceDetails.contains("Partial local usage coverage.")
                            && data.sourceDetails.contains("Missing dates are unknown, not zero.")
                            && data.sourceDetails.contains("Not account-wide usage or billing."),
                            "Saved usage limitations remain available in the tooltip")
                try require(data.sourceDetails.contains("Known recording gaps.") == hasGap,
                            "Tooltip accurately reports recording gaps")
                try require(data.sourceDetails.contains("Usage recorded on 1 of 7 days.") == (range == .week),
                            "Weekly coverage moves to the tooltip")
                data.historyRecording = false
                try require(data.provenance == "Saved locally; recording paused", "Paused recording stays visible")
            }
        }
    }

    static func liveActivity() throws {
        var activity = ActivityState()
        for id in ["one", "two"] {
            _ = try activity.accept(ActivityEvent(source: .cli, session: ActivityEvent.digest(id),
                kind: .active, timestamp: now), now: now)
        }
        var data = NotchPresentation(sessions: Array(activity.sessions.values), now: now)
        try require(data.working.count == 2 && data.clientCounts == "CLI 2 / VS Code 0", "Two live CLI sessions")
        try require(data.activityCoverage == nil, "Fresh sessions need no missing-coverage warning")
        data.now = now.addingTimeInterval(91)
        try require(data.working.isEmpty && data.activityTitle == "Activity updates missing", "Reporters expire honestly")
        _ = try activity.accept(ActivityEvent(source: .cli, session: ActivityEvent.digest("one"),
            kind: .active, timestamp: data.now), now: data.now)
        data.sessions = Array(activity.sessions.values)
        try require(data.working.count == 1 && data.activityCoverage == "1 session without recent updates",
                    "Partial coverage stays visible beside the working count")
        for id in ["one", "two"] {
            _ = try activity.accept(ActivityEvent(source: .cli, session: ActivityEvent.digest(id),
                kind: .idle, timestamp: data.now.addingTimeInterval(1)), now: data.now)
        }
        data.sessions = Array(activity.sessions.values)
        try require(data.working.isEmpty && data.activityTitle == "No work currently reported",
                    "Idle is not observation unavailable")
        var insights = SessionInsights()
        var attention = SessionAttentionState()
        let hash = ActivityEvent.digest("compaction-work")
        let begin = ActivityEvent(source: .cli, session: hash, kind: .working, timestamp: now)
        _ = try activity.accept(begin, now: now)
        try attention.observe(begin, now: now)
        let failure = ActivityEvent(source: .cli, session: hash, kind: .compaction,
            timestamp: now.addingTimeInterval(1), compaction: CompactionUsage(success: false),
            metricID: ActivityEvent.digest("failure"))
        insights.observe(failure, now: failure.timestamp)
        try attention.observe(failure, now: failure.timestamp)
        _ = try activity.accept(ActivityEvent(source: .cli, session: hash, kind: .active,
            timestamp: now.addingTimeInterval(30)), now: now.addingTimeInterval(30))
        data = NotchPresentation(sessions: Array(activity.sessions.values), now: now.addingTimeInterval(30),
                                 insights: insights.sessions)
        applyAttention(attention, to: &data)
        try require(data.sessionRows.first?.title == "Compaction failed", "Liveness refresh must not hide a compaction failure")
        _ = try activity.accept(ActivityEvent(source: .cli, session: hash, kind: .working,
            timestamp: now.addingTimeInterval(31)), now: now.addingTimeInterval(31))
        _ = try activity.accept(ActivityEvent(source: .cli, session: hash, kind: .active,
            timestamp: now.addingTimeInterval(60)), now: now.addingTimeInterval(60))
        data.sessions = Array(activity.sessions.values)
        data.now = now.addingTimeInterval(60)
        try attention.observe(ActivityEvent(source: .cli, session: hash, kind: .working,
            timestamp: now.addingTimeInterval(31)), now: now.addingTimeInterval(31))
        applyAttention(attention, to: &data)
        try require(!data.sessionNotices.contains(where: \.needsHighlight), "New work supersedes the old failure even after another live snapshot")
    }

    static func redesign() throws {
        try modelDisclosure()
        var ledger = TokenLedger()
        for index in 0..<6 {
            try ledger.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("models"),
                kind: .usage, timestamp: now,
                tokens: TokenUsage(callID: ActivityEvent.digest("model-\(index)"), input: Int64(index * 100),
                                   output: 1, model: index == 5 ? nil : "model-\(index)")), now: now)
        }
        var data = NotchPresentation(tokens: ledger.totals, now: now, models: ledger.byModel)
        let liveDetail = LiveUsageDetail(models: ledger.byModel, tokens: ledger.totals, selectedModel: nil,
                                        partial: false, observedAt: now, zone: "UTC")
        try require(!liveDetail.isExpired(now: now.addingTimeInterval(86_399))
                    && liveDetail.isExpired(now: now.addingTimeInterval(86_400)),
                    "Captured live details cannot extend the 24-hour retention window")
        try require(data.modelRows.count == 4 && data.modelRows.last?.model == nil, "Bounded named models and residual")
        try require(data.modelRows.last?.title.contains("unavailable") == true, "Unknown models must be disclosed")
        try require(data.modelRows.reduce(0) { $0 + $1.tokens } == data.usageTotals?.total, "Residual reconciles exact tokens")
        try require(data.modelRows.reduce(0) { $0 + $1.calls } == 6, "Residual reconciles exact calls")
        data.range = .week
        try require(data.usageSource == .needsHistory && data.modelRows.isEmpty && data.usageTotals == nil,
                    "Live memory cannot become seven-day usage")
        data.historyError = "Storage failure"
        try require(data.usageSource == .unavailable && data.usageTotals == nil, "No silent live fallback on storage failure")
        data.historyError = nil
        data.historyLoading = true
        try require(data.usageSource == .loading, "Pending archive detection must not substitute live usage")

        var insights = SessionInsights()
        var attention = SessionAttentionState()
        for (key, fraction, date) in [("high", 85, now.addingTimeInterval(-5)), ("latest", 20, now)] {
            let event = ActivityEvent(source: .cli, session: ActivityEvent.digest(key), kind: .context,
                timestamp: date, context: ContextUsage(currentTokens: Int64(fraction), tokenLimit: 100))
            insights.observe(event, now: now)
            try attention.observe(event, now: now)
        }
        data = NotchPresentation(now: now, insights: insights.sessions)
        applyAttention(attention, to: &data)
        try require(data.sessionRows.first?.target.noticeSessionID == attention.sessionID(source: .cli, hash: ActivityEvent.digest("high")), "Must scan beyond latest session")
        data.now = now.addingTimeInterval(295)
        try require(data.sessionRows.count == 1 && !data.sessionRows[0].detail.contains("stale"), "Five-minute boundary remains fresh")
        data.now = now.addingTimeInterval(296)
        try require(data.sessionRows.count == 1 && data.sessionRows[0].detail.contains("stale"), "Unresolved stale context must be labeled, not resolved")
        data.now = now
        var activity = ActivityState()
        _ = try activity.accept(ActivityEvent(source: .cli, session: ActivityEvent.digest("error"), kind: .failed,
            timestamp: now), now: now)
        data.sessions = Array(activity.sessions.values)
        try attention.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("error"),
            kind: .failed, timestamp: now), now: now)
        applyAttention(attention, to: &data)
        try require(data.sessionRows.first?.signal == .error, "Explicit session failure has priority")
        _ = try activity.accept(ActivityEvent(source: .cli, session: ActivityEvent.digest("error"), kind: .working,
            timestamp: now.addingTimeInterval(1)), now: now)
        data.sessions = Array(activity.sessions.values)
        try attention.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("error"),
            kind: .working, timestamp: now.addingTimeInterval(1)), now: now)
        applyAttention(attention, to: &data)
        try require(data.sessionRows.first?.title.hasPrefix("High context") == true, "Superseded failure cannot persist")
        data.account = try account(used: 80)
        try require(data.quotaWarning != nil, "Exact 80 percent threshold")
        data.accountStale = true
        try require(data.quotaWarning == nil && !data.working.isEmpty, "Stale quota does not hide local work")

        data = NotchPresentation(account: try account(), tokens: ledger.totals, now: now, models: ledger.byModel)
        data.liveTimeline = ledger.hourlyTimeline(now: now)
        let content = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
            .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
        let height = NSHostingView(rootView: content).fittingSize.height + NotchLayout.cardChrome()
        try require(height <= 640, "Four-section card with chart exceeds 640pt: \(height)")
        for source in UsageSource.allCases {
            data.metricSource = source
            let filtered = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
                .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
            let filteredHeight = NSHostingView(rootView: filtered).fittingSize.height + NotchLayout.cardChrome()
            try require(filteredHeight <= 640, "\(source.title) source menu exceeds the compact card limit")
        }
        data.metricSource = nil
        data.insights = insights.sessions
        applyAttention(attention, to: &data)
        let warning = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
            .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
        let warningHeight = NSHostingView(rootView: warning).fittingSize.height + NotchLayout.cardChrome()
        try require(warningHeight <= 680, "Four-section exception card with chart exceeds 680pt: \(warningHeight)")
    }

    static func modelDisclosure() throws {
        let events = modelUsageEvents(at: now)
        let unavailable = ActivityEvent(source: .cli, session: ActivityEvent.digest("model-disclosure"),
            kind: .usage, timestamp: now, tokens: TokenUsage(callID: ActivityEvent.digest("unavailable"),
                input: 75, output: 5))
        var ledger = TokenLedger()
        for count in 0...events.count {
            if count > 0 { try ledger.observe(events[count - 1], now: now) }
            var data = NotchPresentation(tokens: ledger.today(now: now), now: now,
                                         models: ledger.todayByModel(now: now))
            try require(data.canExpandModels == (count > 3), "Disclosure must depend only on the named-model count")
            try require(!data.modelsExpanded && data.modelRows.filter(\.isNamed).count == min(count, 3),
                        "The initial model list must stay compact")
            if count > 3 {
                try require(data.modelRows.last?.title == "Remaining models"
                            && !data.modelRows.contains { $0.model == "claude-opus-5" },
                            "Lower-ranked Opus fixture must start in the residual")
            }
            data.modelsExpanded = true
            try require(data.modelRows.count == count && data.modelRows.allSatisfy(\.isNamed),
                        "Expansion must show every identified model without an empty residual")
            try require(data.modelRows.reduce(0) { $0 + $1.calls } == Int64(count), "Expansion lost a zero-token call")
        }
        try ledger.observe(unavailable, now: now)
        var data = NotchPresentation(tokens: ledger.today(now: now), now: now,
                                     models: ledger.todayByModel(now: now))
        for expanded in [false, true, false] {
            data.modelsExpanded = expanded
            try require(data.modelRows.reduce(0) { $0 + $1.tokens } == 1880
                        && data.modelRows.reduce(0) { $0 + $1.calls } == 7,
                        "Toggling must conserve all tokens and calls")
            try require(data.modelRows.last?.title == "Other / unavailable models",
                        "Unavailable usage must remain disclosed")
            if expanded {
                try require(data.modelRows.compactMap(\.model) ==
                    ["model-a", "model-b", "model-c", "claude-opus-5", "model-zero-a", "model-zero-b"],
                    "Expanded models must retain token order and deterministic tie-breaking")
                try require(data.modelRows.last?.tokens == 80 && data.modelRows.last?.calls == 1,
                            "Expanded named contributions must leave the residual")
            }
        }
        var unknownLedger = TokenLedger()
        try unknownLedger.observe(unavailable, now: now)
        let unknown = NotchPresentation(tokens: unknownLedger.totals, now: now, models: unknownLedger.byModel)
        try require(!unknown.canExpandModels && unknown.modelRows.count == 1,
                    "Unavailable usage alone is not an expandable model list")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-model-disclosure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = HistoryCalendar(zone: TimeZone(secondsFromGMT: 0)!)
        let store = try UsageHistoryStore(root: root, zone: calendar.calendar.timeZone,
                                         now: calendar.addingDays(-7, to: now))
        for offset in [-7, -1, 0] {
            let date = calendar.addingDays(offset, to: now)
            try store.record(modelUsageEvents(at: date), now: date)
        }
        try store.record([unavailable], now: now)
        for range in [HistoryRange.today, .week] {
            data = NotchPresentation(now: now, range: range,
                savedUsage: try store.query(calendar.interval(range, selected: now, now: now)))
            for expanded in [false, true] {
                data.modelsExpanded = expanded
                try require(data.usageSource == .saved && data.canExpandModels,
                            "Both saved periods must support disclosure")
                try require(data.modelRows.reduce(0) { $0 + $1.tokens } == data.usageTotals?.total
                            && data.modelRows.reduce(0) { $0 + $1.calls } == data.usageTotals?.calls,
                            "Saved rows must reconcile with the selected period")
                let opus = data.modelRows.first { $0.model == "claude-opus-5" }
                try require(expanded ? opus?.calls == (range == .today ? 1 : 2) : opus == nil,
                            "Saved expansion must reveal only the selected period's Opus usage")
            }
            try require(data.usageTotals?.calls == (range == .today ? 7 : 13),
                        "Disclosure must not include samples outside the selected period")
        }
        let overflow = (0..<100).map { index in
            ActivityEvent(source: .cli, session: ActivityEvent.digest("detail-limit"), kind: .usage,
                timestamp: now, tokens: TokenUsage(callID: ActivityEvent.digest("detail-limit-\(index)"),
                    input: 1, output: 0, model: "extra-\(index)"))
        }
        try store.record(overflow, now: now)
        data = NotchPresentation(now: now,
            savedUsage: try store.query(calendar.interval(.today, selected: now, now: now)), modelsExpanded: true)
        try require(data.modelRows.filter(\.isNamed).count == 99
                    && data.modelRows.last?.tokens == 87 && data.modelRows.last?.calls == 8,
                    "Expansion cannot invent model identities lost to the archive detail limit")
        try require(data.modelRows.reduce(0) { $0 + $1.tokens } == data.usageTotals?.total
                    && data.modelRows.reduce(0) { $0 + $1.calls } == data.usageTotals?.calls,
                    "Archived overflow must still reconcile")
        data.historyLoading = true
        try require(!data.canExpandModels && data.modelRows.isEmpty, "Loading must not expose stale disclosure rows")
        data.historyError = "Storage failure"
        try require(!data.canExpandModels && data.modelRows.isEmpty, "Errors must not expose stale disclosure rows")
        data = NotchPresentation(range: .week, modelsExpanded: true)
        try require(!data.canExpandModels && data.modelRows.isEmpty && data.usageSource == .needsHistory,
                    "Expansion must not fabricate live seven-day usage")
    }

    static func interactions() throws {
        var state = NotchInteraction()
        try require(state.update(hovered: 0, overDetail: false, now: now) == nil, "Hover delay starts")
        try require(state.update(hovered: 0, overDetail: false, now: now.addingTimeInterval(0.17)) == nil, "No early reveal")
        try require(state.update(hovered: 0, overDetail: false, now: now.addingTimeInterval(0.19)) == .reveal(0), "Hover reveal")
        state.show(pinned: false, now: now)
        try require(state.update(hovered: nil, overDetail: true, now: now.addingTimeInterval(1)) == nil, "Card/corridor retains hover")
        try require(state.update(hovered: nil, overDetail: false, now: now.addingTimeInterval(2)) == nil, "Leave grace")
        try require(state.update(hovered: nil, overDetail: false, now: now.addingTimeInterval(2.26)) == .dismiss, "Leave dismisses")
        state.show(pinned: true, now: now)
        try require(state.update(hovered: nil, overDetail: false, now: now.addingTimeInterval(20)) == nil, "Clicked card stays open")
        state.dismiss()
        try require(!state.isVisible && !state.isPinned, "Outside dismissal clears pin")
        state.show(pinned: false, now: now, minimumDuration: 3)
        try require(state.update(hovered: nil, overDetail: false, now: now.addingTimeInterval(2.9)) == nil, "Notification minimum visibility")
        _ = state.update(hovered: nil, overDetail: false, now: now.addingTimeInterval(3))
        try require(state.update(hovered: nil, overDetail: false, now: now.addingTimeInterval(3.26)) == .dismiss, "Notification closes")
        state.show(pinned: false, now: now, sourceIndex: 0)
        try require(state.update(hovered: 1, overDetail: false, now: now) == nil, "Another display needs hover dwell")
        try require(state.update(hovered: 1, overDetail: false, now: now.addingTimeInterval(0.19)) == .reveal(1),
                    "Hover can transfer expansion to another display")
        state.show(pinned: true, now: now, sourceIndex: 0)
        try require(state.update(hovered: 1, overDetail: false, now: now.addingTimeInterval(1)) == nil,
                    "Hovering another display cannot move a pinned card")
    }

    static func preferences() throws {
        var options = TokenotchOptions()
        try require(options.autoHideNotch, "Idle auto-hide starts enabled")
        try require(options.timeFormat == .twentyFourHour, "Existing 24-hour display must remain the default")
        options.showNotch = false
        options.allDisplays = true
        options.edge = "bottom"
        options.scale = 1.25
        options.displayID = "fixture-display"
        options.foldsForFullScreen = false
        options.offsets = ["bottom": 42]
        options.healthEnabled = true
        options.notifications.sound = true
        let encoded = try JSONEncoder().encode(options)
        guard var legacy = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw NotchCheckFailure.failed("Preferences must encode as an object")
        }
        legacy.removeValue(forKey: "autoHideNotch")
        legacy.removeValue(forKey: "timeFormat")
        let migrated = try JSONDecoder().decode(TokenotchOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(migrated.autoHideNotch && !migrated.showNotch && migrated.allDisplays,
                    "Old preferences enable collapse without re-enabling a hidden notch")
        try require(migrated.edge == "bottom" && migrated.scale == 1.25 && migrated.displayID == options.displayID
                    && !migrated.foldsForFullScreen && migrated.offsets == options.offsets
                    && migrated.healthEnabled && migrated.notifications.sound,
                    "Adding auto-hide must preserve all existing preferences")
        try require(migrated.timeFormat == .twentyFourHour, "Old preferences must migrate to the existing hour format")
        options.autoHideNotch = false
        let saved = try JSONDecoder().decode(TokenotchOptions.self, from: JSONEncoder().encode(options))
        try require(!saved.autoHideNotch, "An explicit always-visible choice survives a preferences round trip")
        legacy["autoHideNotch"] = "invalid"
        do {
            _ = try JSONDecoder().decode(TokenotchOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
            throw NotchCheckFailure.failed("Invalid auto-hide preferences must not silently reset")
        } catch DecodingError.typeMismatch {}
        for format in TimeFormat.allCases {
            options.timeFormat = format
            let restored = try JSONDecoder().decode(TokenotchOptions.self, from: JSONEncoder().encode(options))
            try require(restored.timeFormat == format && !restored.autoHideNotch
                        && restored.offsets == options.offsets && restored.notifications.sound,
                        "Clock preference round trip must preserve the choice and unrelated preferences")
        }
        legacy["autoHideNotch"] = true
        legacy["timeFormat"] = "invalid"
        do {
            _ = try JSONDecoder().decode(TokenotchOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
            throw NotchCheckFailure.failed("Invalid time format must not silently reset")
        } catch DecodingError.dataCorrupted {}
    }

    static func image<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw NotchCheckFailure.failed("SwiftUI render returned no pixels")
        }
        return bitmap
    }

    static func save(_ image: NSBitmapImageRep, name: String, directory: URL?) throws {
        guard let directory else { return }
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw NotchCheckFailure.failed("PNG conversion failed")
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    static func hostedImage<V: View>(_ view: V, size: CGSize, scrollToBottom: Bool = false) throws -> NSBitmapImageRep {
        let panel = NotchPanel(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size))
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if scrollToBottom {
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            guard let scroll = scrollView(in: host), let document = scroll.documentView else {
                throw NotchCheckFailure.failed("Overflow card must expose a native scrollable document")
            }
            try require(document.bounds.height > scroll.contentView.bounds.height, "Overflow needs scrolling")
            let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return try capture(host)
    }

    static func capture(_ host: NSView) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(host.bounds.width * 2)), pixelsHigh: Int(ceil(host.bounds.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NotchCheckFailure.failed("Hosting view capture unavailable")
        }
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    static func sectionHeadings(directory: URL? = nil) throws {
        let populated = try fixture()
        var vscode = populated
        vscode.metricSource = .vscodeCopilot
        var loading = populated
        loading.historyLoading = true
        var unavailable = populated
        unavailable.historyError = "Fixture history unavailable"
        var expanded = populated
        var ledger = TokenLedger()
        for event in modelUsageEvents(at: now) { try ledger.observe(event, now: now) }
        expanded.tokens = ledger.totals
        expanded.models = ledger.byModel
        expanded.modelsExpanded = true
        var requests = NotchPresentation(now: now)
        var attention = SessionAttentionState()
        try attention.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("heading-request"),
            kind: .inputRequested, timestamp: now), now: now)
        applyAttention(attention, to: &requests)
        let fixtures: [(String, NotchPresentation)] = [
            ("empty", NotchPresentation(now: now)), ("usage", populated), ("vscode", vscode),
            ("sessions", try fixture(sessionCount: 8)), ("request", requests),
            ("loading", loading), ("unavailable", unavailable),
            ("needs-history", NotchPresentation(now: now, range: .week)), ("expanded", expanded)
        ]
        let expected = ["Usage", "Sessions", "Models' Usage Chart", "Models Breakdown"]
        for (name, data) in fixtures {
            for scale: CGFloat in [0.75, 1, 1.5] {
                let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
                let content = CopilotSummaryContent(presentation: data, scale: scale,
                    openClient: { _ in }, openHistory: {})
                    .frame(width: width)
                    .padding(NotchLayout.cardPadding * scale)
                    .background(Palette.surface)
                let size = NSHostingView(rootView: content).fittingSize
                let bitmap = try hostedImage(content, size: size)
                try save(bitmap, name: "section-headings-\(name)-\(scale)", directory: directory)
                guard let image = bitmap.cgImage else {
                    throw NotchCheckFailure.failed("Heading fixture image unavailable")
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    .compactMap { $0.topCandidates(1).first?.string.replacingOccurrences(of: "\u{2019}", with: "'") }
                try require(lines.filter { expected.contains($0) } == expected,
                            "\(name)/\(scale): headings must render once, in order, without clipping: \(lines)")
                for title in ["Today", "Last 7 days"] {
                    try require(lines.contains { $0.contains(title) },
                                "\(name)/\(scale): period control must remain visible")
                }
            }
        }
    }

    static func render(directory: URL? = nil) throws {
        let data = try fixture()
        for scale: CGFloat in [0.75, 1, 1.5] {
            let content = CopilotSummaryContent(presentation: data, scale: scale,
                openClient: { _ in }, openHistory: {})
            for count: Int64 in [999_900_000_000, Int64.max / 4] {
                let coverage = TokenBreakdown(
                    read: CacheInputCoverage(tokens: count, calls: 1, reportedCalls: 1, unreportedCalls: 0),
                    write: CacheInputCoverage(tokens: count, calls: 1, reportedCalls: 1, unreportedCalls: 0, kind: .write))
                let row = content.breakdown(input: count, output: count, coverage: coverage)
                let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
                try require(NSHostingView(rootView: row.fixedSize()).fittingSize.width <= width + 1,
                            "Four large token categories clip at scale \(scale)")
            }
        }
        for (name, fixture, _, _) in try cacheFixtures() {
            guard let totals = fixture.usageTotals else { throw NotchCheckFailure.failed("Missing cache fixture") }
            for scale: CGFloat in [0.75, 1, 1.5] {
                let content = CopilotSummaryContent(presentation: fixture, scale: scale,
                    openClient: { _ in }, openHistory: {})
                for count: Int64 in [totals.input, 999_900_000_000, Int64.max] {
                    let row = content.breakdown(input: count, output: count, coverage: totals.breakdown)
                    let intrinsic = NSHostingView(rootView: row.fixedSize()).fittingSize
                    let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
                    try require(intrinsic.width <= width + 1, "Inline \(name) cache clips for \(count) at \(scale): \(intrinsic.width) > \(width)")
                    let rendered = try hostedImage(row.frame(width: width).padding(8 * scale)
                        .background(Palette.surface).preferredColorScheme(.dark),
                        size: CGSize(width: width + 16 * scale, height: intrinsic.height + 16 * scale))
                    if count == totals.input {
                        try save(rendered, name: "cache-inline-\(name)-\(scale)", directory: directory)
                    }
                }
            }
        }
        for edge in NotchEdge.allCases {
            for scale in [0.75, 1, 1.5] {
                let size = NotchLayout.size(edge: edge, scale: scale)
                let reading = CopilotRingReading(quota: data.account?.quotas.first, isStale: false, isWorking: false)
                let bitmap = try image(NotchBadge(reading: reading, edge: edge, scale: scale, open: {})
                    .frame(width: size.width, height: size.height))
                try require(abs(CGFloat(bitmap.pixelsWide) / 2 - size.width) < 1, "Rendered notch width")
                try require(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1 < 0.1, "Rendered corner passes through")
                try save(bitmap, name: "notch-\(edge.rawValue)-\(scale)", directory: directory)
                let collapsed = try image(NotchBadge(reading: reading, edge: edge, scale: scale,
                                                      isCollapsed: true, open: {})
                    .frame(width: size.width, height: size.height)
                    .environment(\.notchReduceMotion, true))
                let pill = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: size),
                                                edge: edge, scale: scale, collapsed: true)
                let pixelScale = CGFloat(collapsed.pixelsWide) / size.width
                var painted = 0
                for y in 0..<collapsed.pixelsHigh {
                    for x in 0..<collapsed.pixelsWide {
                        if let color = collapsed.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                            painted += 1
                            try require(pill.insetBy(dx: -1, dy: -1).contains(
                                CGPoint(x: CGFloat(x) / pixelScale, y: CGFloat(y) / pixelScale)),
                                "Collapsed \(edge) must not paint the full notch or quota ring")
                        }
                    }
                }
                try require(painted > 100, "Collapsed notch must leave a visible edge indicator")
                try save(collapsed, name: "notch-collapsed-\(edge.rawValue)-\(scale)", directory: directory)
            }
        }
        for (name, reading) in [
            ("missing", CopilotRingReading(quota: nil, isStale: false, isWorking: false)),
            ("stale-working", CopilotRingReading(quota: data.account?.quotas.first, isStale: true, isWorking: true)),
            ("unlimited", CopilotRingReading(quota: try account(unlimited: true).quotas.first, isStale: false, isWorking: false)),
            ("attention", CopilotRingReading(quota: nil, isStale: false, isWorking: true, needsAttention: true)),
            ("session-error", CopilotRingReading(quota: nil, isStale: false, isWorking: false, sessionSignal: .error)),
            ("session-warning", CopilotRingReading(quota: nil, isStale: false, isWorking: false, sessionSignal: .warning)),
            ("session-stopped", CopilotRingReading(quota: nil, isStale: false, isWorking: false, sessionSignal: .stopped)),
            ("session-unknown", CopilotRingReading(quota: nil, isStale: false, isWorking: false, sessionSignal: .unknown))
        ] {
            let size = NotchLayout.size(edge: .right, scale: 1)
            let bitmap = try image(NotchBadge(reading: reading, edge: .right, scale: 1, open: {})
                .frame(width: size.width, height: size.height)
                .environment(\.notchReduceMotion, true)
                .environment(\.notchReduceTransparency, true))
            try save(bitmap, name: "notch-\(name)-reduced-motion", directory: directory)
            let collapsed = try image(NotchBadge(reading: reading, edge: .right, scale: 1,
                isCollapsed: true, open: {}).frame(width: size.width, height: size.height)
                .environment(\.notchReduceMotion, true))
            try save(collapsed, name: "notch-collapsed-\(name)", directory: directory)
        }
        var stale = data
        stale.accountStale = true
        stale.accountStatus = "Quota refresh unavailable"
        var unlimited = data
        unlimited.account = try account(unlimited: true)
        var modelLedger = TokenLedger()
        for event in modelUsageEvents(at: now) { try modelLedger.observe(event, now: now) }
        var collapsedModels = data
        collapsedModels.tokens = modelLedger.totals
        collapsedModels.models = modelLedger.byModel
        for index in 0..<20 {
            try modelLedger.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest("render-models"),
                kind: .usage, timestamp: now, tokens: TokenUsage(callID: ActivityEvent.digest("render-model-\(index)"),
                    input: 1, output: 0, model: String(repeating: "long-model-", count: 10) + "\(index)")), now: now)
        }
        var expandedModels = data
        expandedModels.tokens = modelLedger.totals
        expandedModels.models = modelLedger.byModel
        expandedModels.modelsExpanded = true
        var requests = NotchPresentation(now: now)
        var requestNotices = SessionAttentionState()
        for kind in [EventKind.inputRequested, .approvalRequested] {
            try requestNotices.observe(ActivityEvent(source: .cli, session: ActivityEvent.digest(kind.rawValue),
                kind: kind, timestamp: now), now: now)
        }
        applyAttention(requestNotices, to: &requests)
        let fixtures: [(String, NotchPresentation)] = [
            ("usage", data), ("signed-out", NotchPresentation(now: now)),
            ("stale", stale), ("unlimited", unlimited),
            ("models-collapsed", collapsedModels), ("models-expanded", expandedModels),
            ("attention-requests", requests),
            ("sessions", try fixture(sessionCount: 8)),
            ("overflow", try fixture(sessionCount: 100, longCopy: true))
        ] + (try cacheFixtures()).map { ("cache-\($0.0)", $0.1) }
        for (name, fixture) in fixtures {
            for edge in NotchEdge.allCases {
                let notch = CGRect(x: 700, y: 240, width: 70, height: 200)
                let content = CopilotSummaryContent(presentation: fixture, openClient: { _ in }, openHistory: {})
                    .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
                let measured = NSHostingView(rootView: content).fittingSize.height
                try require(measured.isFinite && measured > 100, "Card content has measurable height")
                let constrained = (name == "overflow" || name == "models-expanded") && edge == .right
                let placement = NotchCardPlacement(notch: notch, ringCenter: CGPoint(x: 735, y: 360), edge: edge,
                    visibleFrame: CGRect(x: 0, y: 0, width: 1100, height: constrained ? 270 : 800),
                    contentHeight: measured + NotchLayout.cardChrome())
                let card = CopilotSummaryView(presentation: fixture, placement: placement, openClient: { _ in },
                                              openUsage: {}, openSettings: {}, openHistory: {})
                // ImageRenderer omits macOS ScrollView contents; capture the real hosting view.
                let bitmap = try hostedImage(card, size: placement.frame.size)
                let pixelScale = CGFloat(bitmap.pixelsWide) / placement.frame.width
                try require(abs(bitmap.size.width - placement.frame.width) < 1, "Custom card width")
                let corner = placement.bodyRect.origin
                try require(bitmap.colorAt(x: Int((corner.x + 1) * pixelScale),
                                           y: Int((corner.y + 1) * pixelScale))?.alphaComponent ?? 1 < 0.1,
                            "Rendered card corner must not contain a native popover frame")
                var ink = 0
                let textArea = placement.bodyRect.insetBy(dx: NotchLayout.cardPadding, dy: NotchLayout.cardPadding)
                for y in stride(from: Int(textArea.minY * pixelScale),
                                to: Int((textArea.minY + min(100, textArea.height / 2)) * pixelScale), by: 2) {
                    for x in stride(from: Int(textArea.minX * pixelScale), to: Int(textArea.maxX * pixelScale), by: 2) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.alphaComponent > 0.9, color.redComponent > 0.7,
                           color.greenComponent > 0.7, color.blueComponent > 0.7 { ink += 1 }
                    }
                }
                if directory != nil {
                    let size = CGSize(width: 680, height: 580)
                    let notchSize = NotchLayout.size(edge: .right, scale: 1)
                    let notch = CGRect(x: size.width - notchSize.width, y: (size.height - notchSize.height) / 2,
                                       width: notchSize.width, height: notchSize.height)
                    let local = NotchLayout.ringCenter(in: notchSize, edge: .right, scale: 1)
                    let center = CGPoint(x: notch.minX + local.x, y: notch.maxY - local.y)
                    let content = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
                        .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
                    let height = NSHostingView(rootView: content).fittingSize.height + NotchLayout.cardChrome()
                    let placement = NotchCardPlacement(notch: notch, ringCenter: center, edge: .right,
                                                       visibleFrame: CGRect(origin: .zero, size: size), contentHeight: height)
                    let scene = ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [Color(red: 0.42, green: 0.75, blue: 0.78),
                                                Color(red: 0.75, green: 0.82, blue: 0.64)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        NotchBadge(reading: CopilotRingReading(quota: data.account?.quotas.first,
                            isStale: false, isWorking: false, needsAttention: data.needsAttention),
                            edge: .right, scale: 1, open: {})
                            .frame(width: notch.width, height: notch.height)
                            .position(x: notch.midX, y: size.height - notch.midY)
                        CopilotSummaryView(presentation: data, placement: placement, openClient: { _ in },
                                           openUsage: {}, openSettings: {}, openHistory: {})
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                            .position(x: placement.frame.midX, y: size.height - placement.frame.midY)
                    }.frame(width: size.width, height: size.height)
                    try save(hostedImage(scene, size: size), name: "notch-card-reference-scene", directory: directory)
                }
                try save(bitmap, name: "card-\(name)-\(edge.rawValue)", directory: directory)
                try require(ink > 100, "\(name)/\(edge): card header/content must actually render, not only its footer")
                if constrained {
                    let bottom = try hostedImage(card, size: placement.frame.size, scrollToBottom: true)
                    try save(bottom, name: "card-\(name)-scrolled", directory: directory)
                }
            }
        }
    }

    static func historyRender(directory: URL? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-history-render-\(UUID().uuidString)")
        let domain = "tokenotch-history-render-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let date = Date()
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root,
            now: Calendar.current.date(byAdding: .day, value: -30, to: date)!)
        for index in 0..<30 where index % 5 != 0 {
            let day = Calendar.current.date(byAdding: .day, value: -index, to: date)!
            let event = ActivityEvent(source: .cli, session: ActivityEvent.digest("render"),
                kind: .usage, timestamp: day, tokens: TokenUsage(callID: ActivityEvent.digest("render-\(index)"),
                    input: Int64(1000 * (index + 1)), output: 200,
                    model: index.isMultiple(of: 2) ? "fixture-model-a" : "fixture-model-b",
                    durationMs: 1200, timeToFirstTokenMs: 150))
            try store?.record([event], now: day)
        }
        try store?.record(modelUsageEvents(at: date), now: date)
        store = nil
        let model = TokenotchModel(defaults: defaults, root: root)
        let history = model.history
        try require(NotchPresentation(model: model).savedUsage == nil, "Opt-out must not invent saved usage")
        history.start(available: false)
        defer { history.stop() }
        try waitUntil { !history.notchLoading }
        let view = UsageHistoryView(history: history)
        let bitmap = try hostedImage(view, size: CGSize(width: 820, height: 1050))
        try require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "History view renders")
        try require(history.error == nil && !history.enabled, "Reading history must not opt into collection")
        try save(bitmap, name: "history-daily-comparison", directory: directory)
        let presentation = NotchPresentation(model: model)
        try require(presentation.savedUsage != nil && presentation.provenance.contains("paused"),
                    "Saved paused history must reach the notch presentation")
        try require(history.notchSummary?.change == nil, "Sparse history must not show a percentage")
        guard let comparison = history.comparison, let insight = comparison.insights.first else {
            throw NotchCheckFailure.failed("History did not retain comparison evidence")
        }
        try require(comparison.insights.count == 4 && comparison.insights.allSatisfy { !$0.eligible },
                    "Sparse history must expose four unavailable, inspectable metrics")
        let evidence = comparison.evidence(for: insight)
        let evidenceImage = try hostedImage(HistoryInsightEvidenceView(evidence: evidence),
                                            size: CGSize(width: 800, height: 1000))
        try save(evidenceImage, name: "history-insight-evidence", directory: directory)
        var empty = NotchPresentation(now: date)
        empty.historyLoading = true
        var unavailable = empty
        unavailable.historyError = HistoryError.storage.rawValue
        for (name, data) in [("paused", presentation), ("loading", empty), ("unavailable", unavailable)] {
            let content = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
                .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
            let rendered = try image(content)
            try require(rendered.pixelsHigh > 0, "Notch history state renders")
            try save(rendered, name: "notch-history-\(name)", directory: directory)
        }

        model.options.foldsForFullScreen = false
        var settingsOpened = false
        let fleet = NotchFleet(model: model, openSettings: { settingsOpened = true })
        fleet.start()
        defer { fleet.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        fleet.reveal()
        guard let host = NSApplication.shared.windows.lazy.compactMap({
            $0.isVisible ? $0.contentView as? ShapeHostingView<CopilotSummaryView> : nil
        }).first else {
            throw NotchCheckFailure.failed("History shortcut needs a real notch card")
        }
        try require(host.rootView.presentation.savedUsage != nil, "Fleet did not wire saved history into card")
        let card = host.window
        let compactHeight = card?.frame.height
        let previousKey = NSApplication.shared.keyWindow
        try require(!host.rootView.presentation.modelsExpanded && host.rootView.presentation.canExpandModels,
                    "A newly opened card must show compact model disclosure")
        host.rootView.toggleModels()
        try require(host.rootView.presentation.modelsExpanded
                    && host.rootView.presentation.modelRows.contains { $0.model == "claude-opus-5" },
                    "Show all models must reveal Opus in the existing card")
        try require(host.window === card && card?.isVisible == true && !settingsOpened
                    && NSApplication.shared.keyWindow === previousKey,
                    "Disclosure must not dismiss, open Settings, replace the panel, or steal focus")
        try require((card?.frame.height ?? 0) > (compactHeight ?? 0),
                    "Expansion must remeasure the native panel")
        history.objectWillChange.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try require(card?.isVisible == true && host.rootView.presentation.modelsExpanded,
                    "Published refresh must preserve the expanded card")
        host.rootView.toggleModels()
        try require(!host.rootView.presentation.modelsExpanded, "Show fewer models must restore compact rows")
        try require(abs((card?.frame.height ?? 0) - (compactHeight ?? 0)) <= 1,
                    "Compact panel height changed: \(String(describing: compactHeight)) -> \(String(describing: card?.frame.height))")
        host.rootView.toggleModels()
        host.rootView.selectRange(.week)
        try waitUntil {
            !history.notchLoading && host.rootView.presentation.range == .week
                && host.rootView.presentation.usageSource == .saved
        }
        try require(!host.rootView.presentation.modelsExpanded, "Changing period must reset disclosure")
        host.rootView.toggleModels()
        host.rootView.selectRange(.week)
        try require(host.rootView.presentation.modelsExpanded, "Reselecting the same period must not reset disclosure")
        history.selectNotchRange(.today)
        try waitUntil {
            !history.notchLoading && host.rootView.presentation.range == .today
                && host.rootView.presentation.usageSource == .saved
        }
        try require(!host.rootView.presentation.modelsExpanded, "External period changes must also reset disclosure")
        host.rootView.toggleModels()
        host.rootView.openHistory()
        try require(settingsOpened && model.settingsTab == .history, "History shortcut did not select Settings -> History")
        try require(model.history.navigation?.range == .today && model.history.navigation?.model == nil,
                    "History shortcut must preserve selected range and clear filters")
        try require(card?.isVisible != true, "History shortcut left notch card pinned open")
        history.selectNotchRange(.week)
        try waitUntil { !history.notchLoading }
        try require(history.notchUsage?.totals.calls == 11, "Seven-day models must exclude older archive days")
        fleet.reveal()
        guard let modelHost = NSApplication.shared.windows.lazy.compactMap({
            $0.isVisible ? $0.contentView as? ShapeHostingView<CopilotSummaryView> : nil
        }).first else { throw NotchCheckFailure.failed("Missing model shortcut card") }
        try require(modelHost.rootView.presentation.range == .week, "Range did not survive reopening")
        try require(!modelHost.rootView.presentation.modelsExpanded && modelHost.rootView.presentation.modelRows.count == 4,
                    "Reopening must restore compact models")
        modelHost.rootView.toggleModels()
        try require(modelHost.rootView.presentation.modelRows.count == 8, "Seven-day expansion lost model rows")
        modelHost.rootView.openModel("claude-opus-5")
        try require(model.settingsTab == .history && history.navigation?.range == .week
                    && history.navigation?.model == "claude-opus-5", "Expanded model route lost its period or filter")
        let settingsImage = try hostedImage(SettingsView(model: model), size: CGSize(width: 820, height: 900))
        try save(settingsImage, name: "history-model-drilldown", directory: directory)
        try require(history.navigation == nil, "History navigation must be consumed once")
        fleet.reveal()
        guard let residualHost = NSApplication.shared.windows.lazy.compactMap({
            $0.isVisible ? $0.contentView as? ShapeHostingView<CopilotSummaryView> : nil
        }).first else { throw NotchCheckFailure.failed("Missing residual model route") }
        residualHost.rootView.openModel(nil)
        try require(history.navigation?.range == .week && history.navigation?.model == nil,
                    "Residual route must clear a previous model filter")
        history.selectedEvidence = evidence
        try require(history.selectedEvidence?.id == evidence.id, "History must retain exact insight evidence")
        model.showTimeline(source: .cli, hash: ActivityEvent.digest("render"))
        try require(model.settingsTab == .sessions, "Timeline link did not open Sessions")
        let timelineImage = try hostedImage(SessionTimelineView(timeline: model.timeline, attention: model.attention),
                                            size: CGSize(width: 820, height: 900))
        try save(timelineImage, name: "timeline-consent", directory: directory)
        try require(!model.timeline.enabled, "Timeline navigation opted into recording")
        try save(try hostedImage(AboutSettingsView(updates: model.updates), size: CGSize(width: 820, height: 1000)),
                 name: "settings-about", directory: directory)
        try save(try hostedImage(SettingsSidebar(model: model), size: CGSize(width: 200, height: 520)),
                 name: "settings-sidebar", directory: directory)
    }

    static func fullScreenDetection() throws {
        let laptop = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let external = CGRect(x: -1949, y: -1440, width: 5120, height: 1440)
        let fullScreenWindow = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        let externalWindow = CGRect(x: 1356, y: -1406, width: 1811, height: 1400)
        // An Electron app in full screen: the auto-hiding toolbar above the
        // full-screen window belongs to a helper process, not the window's owner.
        let helperToolbar = CGRect(x: 0, y: 39, width: 1800, height: 32)
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (10, 25, laptop),
            (10, 0, CGRect(x: 200, y: 200, width: 600, height: 600)),
            (20, 0, externalWindow),
            (31, 0, helperToolbar),
            (30, 0, fullScreenWindow)
        ]
        try require(FullScreenDetector.isFullScreenOnDisplay(screenBounds: laptop, windows: windows,
            ownPID: 10, safeAreaTopInset: 38), "A helper process above the full-screen window still hides the notch")
        try require(!FullScreenDetector.isFullScreenOnDisplay(screenBounds: external, windows: windows,
            ownPID: 10), "A normal desktop on another display keeps its notch")
        try require(FullScreenDetector.isFullScreenOnDisplay(screenBounds: external,
            windows: [(30, 0, fullScreenWindow), (20, 0, external)], ownPID: 10),
            "Full-screen detection supports negative display coordinates")
        try require(FullScreenDetector.isFullScreenOnDisplay(screenBounds: laptop,
            windows: [(20, 0, CGRect(x: 100, y: 100, width: 900, height: 700)), (30, 0, laptop)],
            ownPID: 10), "A full-screen window is found behind an ordinary window in front of it")
        try require(!FullScreenDetector.isFullScreenOnDisplay(screenBounds: laptop,
            windows: [(20, 0, CGRect(x: 0, y: 39, width: 1800, height: 1072))], ownPID: 10),
            "A window zoomed against the Dock is not full screen")
        try require(!FullScreenDetector.isFullScreenOnDisplay(screenBounds: external,
            windows: [(20, 0, CGRect(x: -1943, y: -1410, width: 1270, height: 1404))], ownPID: 10),
            "An ordinary window on an ultrawide display is not full screen")
        // A second display usually carries no Dock, so a zoomed window runs all
        // the way to the bottom edge and used to be read as full screen. That
        // took the notch off that display while the built-in one kept its own.
        let externalVisible = CGRect(x: -1949, y: -1410, width: 5120, height: 1410)
        let externalZoomed: [(pid: pid_t, layer: Int, bounds: CGRect)] = [(20, 0, externalVisible)]
        try require(!FullScreenDetector.isFullScreenOnDisplay(screenBounds: external, windows: externalZoomed,
            ownPID: 10, visibleBounds: externalVisible),
            "A window zoomed on a display without a Dock is not full screen")
        try require(FullScreenDetector.isFullScreenOnDisplay(screenBounds: external,
            windows: [(20, 0, external)], ownPID: 10, visibleBounds: externalVisible),
            "A genuine full-screen window still hides that display's notch")
        try require(FullScreenDetector.isFullScreenOnDisplay(screenBounds: external,
            windows: [(20, 0, CGRect(x: -1943, y: -1410, width: 1270, height: 1404)), (30, 0, external)],
            ownPID: 10), "A narrow window in front does not mask a full-screen app on an ultrawide display")
        try require(!FullScreenDetector.isFullScreenOnDisplay(screenBounds: laptop,
            windows: [(10, 0, laptop), (20, 25, laptop), (30, 0, externalWindow)], ownPID: 10),
            "Own windows, overlays and other displays do not count as full screen")
        try require(!FullScreenDetector.isFullScreenOnDisplay(screenBounds: laptop, windows: [], ownPID: 10),
            "An empty desktop does not count as full screen")
    }

    static func fullScreenVisibility() throws {
        let application = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw NotchCheckFailure.failed("Full-screen checks need a display")
        }
        let suite = "Tokenotch.FullScreenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TokenotchModel(defaults: defaults)
        model.options.displayID = screen.displayIdentifier
        var fullScreen = false
        var detectionCount = 0
        let fleet = NotchFleet(model: model, openSettings: {}, isFullScreen: { _ in
            detectionCount += 1
            return fullScreen
        })
        let before = Set(application.windows.map(ObjectIdentifier.init))
        func visibleWindows() -> [NSWindow] {
            application.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        }
        fleet.start()
        defer { fleet.stop() }
        settle()
        try require(visibleWindows().count == 1, "Normal desktop shows the notch")
        fleet.reveal()
        try require(visibleWindows().count == 2, "Detail card starts visible")

        // The Space notification may precede the final full-screen window bounds.
        fullScreen = true
        settle()
        try require(visibleWindows().isEmpty, "A delayed full-screen transition hides notch and detail without another notification")
        fleet.reveal(allowSettings: false)
        try require(visibleWindows().isEmpty, "Activity cannot reveal a hidden full-screen notch")

        fullScreen = false
        settle()
        try require(visibleWindows().count == 1, "Exiting full screen restores only the notch")
        fullScreen = true
        settle()
        model.options.foldsForFullScreen = false
        settle()
        try require(visibleWindows().count == 1, "Disabling full-screen hiding restores the notch")
        let countWhileDisabled = detectionCount
        settle()
        try require(detectionCount == countWhileDisabled, "Disabled setting skips full-screen detection")
        model.options.foldsForFullScreen = true
        settle()
        try require(visibleWindows().isEmpty, "Enabling full-screen hiding takes effect immediately")
        fullScreen = false
        model.options.showNotch = false
        settle()
        try require(visibleWindows().isEmpty, "Full-screen exit respects the master visibility setting")
        fleet.stop()
        let countAfterStop = detectionCount
        settle()
        try require(detectionCount == countAfterStop && visibleWindows().isEmpty, "Stopping cancels visibility polling")
    }

    static func autoHide() throws {
        let application = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw NotchCheckFailure.failed("Auto-hide checks need a display")
        }
        let suite = "Tokenotch.AutoHideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TokenotchModel(defaults: defaults)
        model.options.displayID = screen.displayIdentifier
        model.options.foldsForFullScreen = false
        let away = CGPoint(x: screen.frame.minX + 2, y: screen.frame.minY + 2)
        var pointer = away
        let fleet = NotchFleet(model: model, openSettings: {}, pointerLocation: { pointer })
        let before = Set(application.windows.map(ObjectIdentifier.init))
        func windows() -> [NotchPanel] {
            application.windows.compactMap { window in
                guard !before.contains(ObjectIdentifier(window)), window.isVisible else { return nil }
                return window as? NotchPanel
            }
        }
        func settle(_ duration: TimeInterval = 0.5) {
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
        }
        func badge() throws -> (NotchPanel, ShapeHitTesting) {
            guard let panel = windows().first(where: { !($0.contentView is ShapeHostingView<CopilotSummaryView>) }),
                  let host = panel.contentView as? ShapeHitTesting else {
                throw NotchCheckFailure.failed("No notch badge available")
            }
            return (panel, host)
        }
        guard let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw NotchCheckFailure.failed("Unable to construct outside-click fixture")
        }
        fleet.start()
        defer { fleet.stop() }
        for edge in NotchEdge.allCases {
            pointer = away
            model.options.edge = edge.rawValue
            settle()
            let (panel, host) = try badge()
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let pill = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: panel.frame.size),
                                            edge: edge, scale: 1, collapsed: true)
            let indicator = CGPoint(x: panel.frame.minX + pill.midX, y: panel.frame.maxY - pill.midY)
            try require(!host.contains(screenPoint: center), "Idle \(edge) must collapse instead of keeping the ring visible")
            try require(host.contains(screenPoint: indicator), "Idle \(edge) indicator remains hoverable")
            pointer = center
            settle()
            try require(windows().count == 1 && panel.ignoresMouseEvents,
                        "Transparent space around the collapsed notch must neither reveal nor capture clicks")
            pointer = indicator
            settle()
            try require(windows().count == 2 && host.contains(screenPoint: center) && !panel.ignoresMouseEvents,
                        "Hovering the \(edge) indicator expands the ring and detail card")
            guard let card = windows().first(where: { $0 !== panel }),
                  let cardHost = card.contentView as? ShapeHostingView<CopilotSummaryView> else {
                throw NotchCheckFailure.failed("Hover did not reveal a detail card")
            }
            let placement = cardHost.rootView.placement
            pointer = CGPoint(x: placement.hoverBridge.midX, y: placement.hoverBridge.midY)
            settle()
            try require(windows().count == 2, "Crossing the notch/card gap must not collapse the notch")
            pointer = CGPoint(x: card.frame.midX, y: card.frame.midY)
            settle()
            try require(windows().count == 2, "Interacting with the detail card keeps the notch expanded")
            pointer = away
            settle(0.7)
            try require(windows().count == 1 && !host.contains(screenPoint: center) && panel.ignoresMouseEvents,
                        "Leaving the \(edge) notch and card returns to the edge indicator")
            panel.onClick?(.zero)
            settle()
            try require(windows().count == 2 && host.contains(screenPoint: center), "A click pins the expanded notch")
            fleet.handlePointerEvent(click)
            try require(windows().count == 1 && !host.contains(screenPoint: center), "An outside click unpins and collapses")
            panel.onDragStart?()
            try require(host.contains(screenPoint: center), "Dragging the compact indicator expands the notch")
            fleet.handlePointerEvent(click)
            try require(host.contains(screenPoint: center), "Outside pointer events must not collapse an active drag")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            settle()
            try require(panel.isVisible && host.contains(screenPoint: center),
                        "Pointer polling and app activation must not replace or collapse a dragged notch")
            panel.onDragEnd?()
            settle()
            let (restoredPanel, restoredHost) = try badge()
            try require(!restoredHost.contains(screenPoint: CGPoint(x: restoredPanel.frame.midX, y: restoredPanel.frame.midY)),
                        "Ending a drag away from the notch restores the compact indicator")
        }
        model.options.autoHideNotch = false
        settle()
        let (expanded, expandedHost) = try badge()
        try require(expandedHost.contains(screenPoint: CGPoint(x: expanded.frame.midX, y: expanded.frame.midY)),
                    "Disabling auto-hide keeps the ring visible at rest")
        model.options.autoHideNotch = true
        settle()
        let (collapsed, collapsedHost) = try badge()
        let center = CGPoint(x: collapsed.frame.midX, y: collapsed.frame.midY)
        try require(!collapsedHost.contains(screenPoint: center), "Enabling auto-hide collapses immediately")
        fleet.reveal(allowSettings: false)
        try require(windows().count == 2 && collapsedHost.contains(screenPoint: center), "Notifications can temporarily expand")
        settle(2.5)
        try require(windows().count == 2, "Notification reveal respects its minimum duration")
        settle(1)
        try waitUntil { windows().count == 1 && !collapsedHost.contains(screenPoint: center) }
        try require(windows().count == 1 && !collapsedHost.contains(screenPoint: center), "Notification reveal returns to a pill")
        model.options.allDisplays = true
        model.options.edge = "right"
        settle()
        let notches = windows()
        try require(notches.count == NSScreen.screens.count, "Every display has an idle indicator")
        for notch in notches {
            let pill = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: notch.frame.size),
                                            edge: .right, scale: 1, collapsed: true)
            pointer = CGPoint(x: notch.frame.minX + pill.midX, y: notch.frame.maxY - pill.midY)
            settle()
            try require(windows().count == notches.count + 1, "Moving between displays keeps exactly one detail card")
            for candidate in notches {
                guard let host = candidate.contentView as? ShapeHitTesting else {
                    throw NotchCheckFailure.failed("Display indicator has no shape hit test")
                }
                let expanded = host.contains(screenPoint: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
                try require(expanded == (candidate === notch), "Only the hovered display expands")
            }
        }
        pointer = away
        settle(0.7)
        model.options.showNotch = false
        settle()
        try require(windows().isEmpty, "The master hide setting removes even the compact indicator")
    }

    static func windows() throws {
        let application = NSApplication.shared
        let previousKey = application.keyWindow
        let panel = NotchPanel(contentRect: CGRect(x: 100, y: 100, width: 100, height: 100))
        let host = ShapeHostingView(rootView: Circle().fill(Color.black))
        host.hitPath = { Circle().path(in: $0) }
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        try require(!panel.canBecomeKey && !panel.canBecomeMain, "Details must not steal focus")
        try require(application.keyWindow === previousKey, "Ordering the panel must retain keyboard focus")
        try require(host.contains(screenPoint: CGPoint(x: 150, y: 150)), "Shape center accepts input")
        try require(!host.contains(screenPoint: CGPoint(x: 101, y: 101)), "Transparent corner rejects input")
        let suite = "Tokenotch.NotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-notch-routes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TokenotchModel(defaults: defaults, root: root)
        model.history.start(available: false)
        defer { model.history.stop() }
        try waitUntil { !model.history.notchLoading }
        model.options.foldsForFullScreen = false
        model.options.allDisplays = true
        var settingsOpened = false
        let fleet = NotchFleet(model: model, openSettings: { settingsOpened = true })
        let before = Set(application.windows.map(ObjectIdentifier.init))
        fleet.start()
        defer { fleet.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let notches = application.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        try require(notches.count == NSScreen.screens.count, "One notch per display")
        fleet.reveal()
        fleet.reveal(allowSettings: false)
        let visible = application.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        try require(visible.count == notches.count * 2, "Automatic reveal opens one detail panel per display")
        try require(application.keyWindow === previousKey, "Hover/reveal must not steal keyboard focus")
        fleet.reveal(keyboard: true)
        let detail = visible.first { !notches.contains($0) && $0.isVisible }
        try require(visible.filter(\.isVisible).count == notches.count + 1,
                    "Deliberate opening keeps only its own detail card")
        try require(detail?.canBecomeKey == true && application.keyWindow === detail,
                    "Explicit menu opening must enable keyboard interaction")
        guard let draggable = notches.first as? NotchPanel else {
            throw NotchCheckFailure.failed("No notch panel for drag checks")
        }
        draggable.onDragStart?()
        try require(visible.filter { !notches.contains($0) }.allSatisfy { !$0.isVisible }, "Drag closes detail card")
        draggable.onDrag?(0, 32)
        draggable.onDragEnd?()
        try require(abs((model.options.offsets["right"] ?? 0) - 32) < 1, "Drag persists along-edge offset")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func currentCard() throws -> ShapeHostingView<CopilotSummaryView> {
            fleet.reveal()
            guard let card = application.windows.lazy.compactMap({
                $0.isVisible ? $0.contentView as? ShapeHostingView<CopilotSummaryView> : nil
            }).first else { throw NotchCheckFailure.failed("Missing route test card") }
            return card
        }
        for format in TimeFormat.allCases {
            model.options.timeFormat = format
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let card = try currentCard()
            try require(card.rootView.presentation.timeFormat == format,
                        "Changing Settings must reach the displayed chart without restarting")
        }
        let refreshedActivityCard = try currentCard()
        refreshedActivityCard.rootView.openActivity()
        try require(model.showLiveSessions && model.settingsTab == .usage && refreshedActivityCard.window?.isVisible != true,
                    "Activity route must expand live sessions and dismiss the card")
        let accountCard = try currentCard()
        accountCard.rootView.openUsage()
        try require(!model.showLiveSessions && model.settingsTab == .usage, "Account route must not bury allowance below sessions")
        let liveCard = try currentCard()
        liveCard.rootView.openModel(nil)
        try require(model.liveUsageDetail != nil && model.settingsTab == .usage && !model.history.enabled,
                    "Live model drill-down must not open unrelated history or opt in")
        model.clearLocalHistory()
        try require(model.liveUsageDetail == nil, "Clearing live observations must clear captured drill-downs")
        settingsOpened = false
        model.options.showNotch = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        fleet.reveal(allowSettings: false)
        try require(!settingsOpened, "Notification reveal never falls back to Settings")
        fleet.reveal()
        try require(settingsOpened, "Explicit reveal keeps the Settings fallback")
        fleet.stop()
        try require(application.windows.filter { !before.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                    "Rebuild/stop closes all owned windows")
    }
}
