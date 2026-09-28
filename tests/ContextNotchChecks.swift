import AppKit
import TokenotchCore
import SwiftUI
import Vision
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum ContextNotchChecks {
    static func run(directory: URL? = nil) throws {
        try attentionTransitions()
        let now = NotchChecks.now
        var activity = ActivityState()
        var insights = SessionInsights()
        for (source, name, count) in [(Client.cli, "one", 25), (.cli, "two", 85), (.vscode, "one", 0)] {
            let hash = ActivityEvent.digest(name)
            _ = try activity.accept(ActivityEvent(source: source, session: hash, kind: source == .cli ? .active : .working,
                                                   timestamp: now), now: now)
            if source == .cli {
                insights.observe(ActivityEvent(source: source, session: hash, kind: .context, timestamp: now,
                    context: ContextUsage(currentTokens: Int64(count), tokenLimit: 100)), now: now)
            }
        }
        var data = NotchPresentation(sessions: Array(activity.sessions.values), now: now, insights: insights.sessions)
        data.metricSource = .vscodeLocal
        data.range = .week
        try NotchChecks.require(data.sessionRows.count == 3, "Every visible live session must have a context slot")
        for row in data.sessionRows {
            let context = data.context(for: row.target)
            let count = row.target.liveHash == ActivityEvent.digest("one") ? 25 : 85
            try NotchChecks.require(context?.usage.currentTokens == (row.target.source == .cli ? Int64(count) : nil),
                                   "Session context must be source-scoped and independent of usage filters/periods")
        }
        for scale: CGFloat in [0.75, 1, 1.5] {
            let content = CopilotSummaryContent(presentation: data, scale: scale, openClient: { _ in }, openHistory: {})
            let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
            let rows = VStack(spacing: 8 * scale) {
                ForEach(data.sessionRows) { content.sessionRow($0) }
            }
            .frame(width: width).padding(12 * scale)
            .background(Palette.surface).preferredColorScheme(.dark)
            let size = NSHostingView(rootView: rows).fittingSize
            let bitmap = try NotchChecks.hostedImage(rows, size: size)
            try NotchChecks.save(bitmap, name: "session-context-rows-\(scale)", directory: directory)
            guard let image = bitmap.cgImage else { throw NotchCheckFailure.failed("Context row image missing") }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations = request.results ?? []
            let contexts = observations.filter { $0.topCandidates(1).first?.string.contains("Context") == true }
            let statuses = observations.filter { $0.topCandidates(1).first?.string.contains("Observed for") == true }
            try NotchChecks.require(contexts.count == 3 && statuses.count == 3,
                                   "Each session must render its own Context label beneath its status at scale \(scale)")
            let contextY = contexts.map(\.boundingBox.midY).sorted(by: >)
            let statusY = statuses.map(\.boundingBox.midY).sorted(by: >)
            try NotchChecks.require(zip(contextY, statusY).allSatisfy { $0 < $1 },
                                   "Context meters must be under their session status, not elsewhere in the stats")
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            try NotchChecks.require(text.contains("25%") && text.contains("85%") && text.contains("Not reported"),
                                   "Independent session percentages and unavailable context must remain legible")
        }

        let one = ActivityEvent.digest("one")
        let invalidation = ActivityEvent(source: .cli, session: one, kind: .contextInvalidated,
            timestamp: now.addingTimeInterval(1), metricID: ActivityEvent.digest("context-reset"))
        insights.observe(invalidation, now: invalidation.timestamp)
        data.insights = insights.sessions
        let target = SessionDetailTarget(source: .cli, noticeSessionID: one, liveHash: one)
        try NotchChecks.require(data.context(for: target) == nil, "Reset removes the notch's obsolete context")
        let states: [(String, ObservedContext?)] = [
            ("unknown", nil),
            ("zero", ObservedContext(usage: ContextUsage(currentTokens: 0, tokenLimit: 100), observedAt: now)),
            ("over-limit", ObservedContext(usage: ContextUsage(currentTokens: 120, tokenLimit: 100), observedAt: now)),
            ("stale", ObservedContext(usage: ContextUsage(currentTokens: 85, tokenLimit: 100),
                                     observedAt: now.addingTimeInterval(-301)))
        ]
        for (name, reading) in states {
            let meter = SessionContextMeter(context: reading, source: .cli, now: now, onNotch: true)
            if name == "unknown" { try NotchChecks.require(meter.value == "Not reported", "Unknown must not mean zero") }
            if name == "zero" { try NotchChecks.require(meter.value == "0%", "Reported zero must remain a numeric reading") }
            if name == "over-limit" { try NotchChecks.require(meter.value == "120%", "Over-limit text cannot be clamped") }
            if name == "stale" { try NotchChecks.require(meter.value == "85% (stale)", "Stale data must not disappear or look current") }
            if reading != nil {
                try NotchChecks.require(meter.details.contains("context tokens") && meter.details.contains("Last reported"),
                                       "Accessible/hover details must include exact counts and observation time")
            }
            let image = try NotchChecks.image(meter.frame(width: 200).padding(10).background(Palette.surface)
                .preferredColorScheme(.dark))
            try NotchChecks.save(image, name: "session-context-\(name)", directory: directory)
        }
    }

    private static func attentionTransitions() throws {
        let now = NotchChecks.now
        var activity = ActivityState()
        var insights = SessionInsights()
        for (name, tokens) in [("needs-attention", 6), ("other-session", 76)] {
            let hash = ActivityEvent.digest(name)
            _ = try activity.accept(ActivityEvent(source: .cli, session: hash, kind: .active,
                                                   timestamp: now), now: now)
            insights.observe(ActivityEvent(source: .cli, session: hash, kind: .context, timestamp: now,
                context: ContextUsage(currentTokens: Int64(tokens), tokenLimit: 100)), now: now)
        }
        let requestedSession = ActivityEvent.digest("needs-attention")
        for kind in [EventKind.inputRequested, .approvalRequested, .stopped] {
            var attention = SessionAttentionState()
            let date = now.addingTimeInterval(1)
            try attention.observe(ActivityEvent(source: .cli, session: requestedSession, kind: kind,
                                                 timestamp: date), now: date)
            var data = NotchPresentation(sessions: Array(activity.sessions.values), now: date, insights: insights.sessions)
            NotchChecks.applyAttention(attention, to: &data)
            guard let row = data.sessionRows.first else { throw NotchCheckFailure.failed("Missing attention row") }
            try NotchChecks.require(row.target.liveHash == requestedSession && row.notice != nil,
                                   "Attention must promote the requesting session, not change its identity")
            let meter = SessionContextMeter(context: data.context(for: row.target), source: .cli, now: date)
            try NotchChecks.require(meter.value == "6%",
                                   "Input, approval and stopped notices must keep this session's 6%, not another session's 76%")
            let other = data.sessionRows.first { $0.target.liveHash == ActivityEvent.digest("other-session") }
            try NotchChecks.require(other.map { data.context(for: $0.target)?.usage.currentTokens } == 76,
                                   "Reordering attention rows must preserve the other session's independent context")
        }
    }
}
