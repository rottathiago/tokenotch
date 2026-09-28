import Foundation
import TokenotchCore
import SwiftUI

enum SessionSignal: Equatable {
    case error, input, approval, warning, stopped, working, unknown, idle

    var color: Color {
        switch self {
        case .error: return Palette.sessionError
        case .input, .approval: return Palette.sessionWarning
        case .warning: return Palette.sessionWarning
        case .stopped: return Palette.sessionStopped
        case .working: return Palette.sessionWorking
        case .unknown, .idle: return Palette.secondary
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .input: return "questionmark.bubble.fill"
        case .approval: return "hand.raised.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .working: return "circle.dotted"
        case .unknown: return "questionmark.circle"
        case .idle: return "minus.circle"
        }
    }

    var priority: Int {
        switch self {
        case .error: return 0
        case .input, .approval: return 1
        case .warning: return 2
        case .stopped: return 3
        case .working: return 4
        case .unknown: return 5
        case .idle: return 6
        }
    }

    init(_ kind: SessionNoticeKind) {
        switch kind {
        case .error: self = .error
        case .input: self = .input
        case .approval: self = .approval
        case .compaction, .context: self = .warning
        case .stopped: self = .stopped
        }
    }
}

struct NotchSessionRow: Identifiable {
    let target: SessionDetailTarget
    let signal: SessionSignal
    let title: String
    let detail: String
    let notice: SessionNotice?
    let date: Date
    var id: String { target.id }
    var label: String { "\(target.source == .cli ? "CLI" : "VS Code") \(target.noticeSessionID.prefix(6))" }
}

struct LiveUsageDetail {
    let models: [ObservedModelTokens]
    let tokens: ObservedTokens?
    let selectedModel: String?
    let partial: Bool
    let observedAt: Date
    let zone: String

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(tokens?.since ?? observedAt) >= 86_400
    }
}

struct NotchModelRow: Identifiable {
    let model: String?
    let title: String
    let input: Int64
    let output: Int64
    let cacheInput: Int64
    let calls: Int64
    var cacheReportedCalls: Int64 = 0
    var cacheUnreportedCalls: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWriteReportedCalls: Int64 = 0
    var cacheWriteUnreportedCalls: Int64 = 0
    var unverifiedCalls: Int64 = 0
    var tokens: Int64 { input + output + cacheInput + cacheWrite }
    var cacheCoverage: CacheInputCoverage {
        CacheInputCoverage(tokens: cacheInput, calls: calls,
            reportedCalls: cacheReportedCalls, unreportedCalls: cacheUnreportedCalls)
    }
    var id: String { model.map { "model:\($0)" } ?? "residual" }
    var breakdown: TokenBreakdown {
        TokenBreakdown(read: cacheCoverage,
            write: CacheInputCoverage(tokens: cacheWrite, calls: calls,
                reportedCalls: cacheWriteReportedCalls, unreportedCalls: cacheWriteUnreportedCalls, kind: .write),
            unverifiedCalls: unverifiedCalls)
    }
    var isNamed: Bool { model != nil && model != "" && model != "*" }
}

extension NotchModelRow {
    init(_ value: HistoryModel) {
        self.init(model: value.id, title: value.title, input: value.tokens.input,
                  output: value.tokens.output, cacheInput: value.tokens.cacheInput, calls: value.tokens.calls,
                  cacheReportedCalls: value.tokens.cacheReportedCalls,
                  cacheUnreportedCalls: value.tokens.cacheUnreportedCalls,
                  cacheWrite: value.tokens.cacheWrite,
                  cacheWriteReportedCalls: value.tokens.cacheWriteReportedCalls,
                  cacheWriteUnreportedCalls: value.tokens.cacheWriteUnreportedCalls,
                  unverifiedCalls: value.tokens.unverifiedCalls)
    }

    init(_ value: ObservedModelTokens) {
        self.init(model: value.model ?? "", title: value.title, input: value.tokens.input,
                  output: value.tokens.output, cacheInput: value.tokens.cacheInput, calls: Int64(value.tokens.calls),
                  cacheReportedCalls: value.tokens.cacheReportedCalls,
                  cacheUnreportedCalls: value.tokens.cacheUnreportedCalls,
                  cacheWrite: value.tokens.cacheWrite,
                  cacheWriteReportedCalls: value.tokens.cacheWriteReportedCalls,
                  cacheWriteUnreportedCalls: value.tokens.cacheWriteUnreportedCalls)
    }
}

struct NotchAttention {
    let title: String
    let session: ObservedSession?
    let sessionID: String?
    let priority: Int
    let date: Date
}

enum NotchUsageSource {
    case saved, live, loading, needsHistory, unavailable
}

struct NotchPresentation {
    var account: CopilotAccountSnapshot?
    var accountStatus = "Not connected"
    var accountStale = false
    var tokens: ObservedTokens?
    var tokensPartial = false
    var sessions: [ObservedSession] = []
    var now = Date()
    var historyError: String?
    var models: [ObservedModelTokens] = []
    var insights: [SessionInsight] = []
    var range: HistoryRange = .today
    var savedUsage: HistorySnapshot?
    var savedTimeline: UsageTimeline?
    var liveTimeline: UsageTimeline?
    var historyLoading = false
    var historyRecording = false
    var anchor: Date?
    var healthIncident = false
    var healthObservedAt: Date?
    var modelsExpanded = false
    var sessionNotices: [SessionNotice] = []
    var noticeSessionIDs: [String: String] = [:]
    var restoredNoticeIDs = Set<String>()
    var heldNoticeIDs = Set<String>()
    var noticeStorageMessage: String?
    var timeFormat: TimeFormat = .twentyFourHour
    var metricSource: UsageSource?

    static func fresh(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) <= 300
    }

    var working: [ObservedSession] {
        sessions.filter { $0.isWorking(now: now) }
    }

    var staleSessionCount: Int {
        sessions.filter { $0.hasMissingActivity(now: now) }.count
    }

    var activityTitle: String {
        let rows = allSessionRows
        let errors = rows.filter { $0.signal == .error }.count
        if errors > 0 { return "\(errors) \(errors == 1 ? "session reported an error" : "sessions reported errors")" }
        let requests = rows.filter { $0.signal == .input || $0.signal == .approval }.count
        if requests > 0 {
            return "\(requests) \(requests == 1 ? "session requested attention" : "sessions requested attention")"
        }
        let warnings = rows.filter { $0.signal == .warning }.count
        if warnings > 0 { return "\(warnings) \(warnings == 1 ? "session has a warning" : "sessions have warnings")" }
        let stopped = rows.filter { $0.signal == .stopped }.count
        if stopped > 0 {
            return "\(stopped) \(stopped == 1 ? "session stopped" : "sessions stopped")" +
                (working.isEmpty ? "" : "; \(working.count) working")
        }
        if !working.isEmpty { return "\(working.count) working" }
        if sessions.isEmpty { return "No recent activity observed" }
        if staleSessionCount > 0 { return "Activity updates missing" }
        if sessions.contains(where: { $0.kind == .started }) { return "Awaiting activity report" }
        return "No work currently reported"
    }

    var sessionSignal: SessionSignal {
        allSessionRows.first?.signal ?? (staleSessionCount > 0 ? .unknown : .idle)
    }

    var sessionRows: [NotchSessionRow] { Array(allSessionRows.prefix(3)) }

    func context(for target: SessionDetailTarget) -> ObservedContext? {
        guard target.source == .cli, let hash = target.liveHash else { return nil }
        return insights.first { $0.id == hash }?.context
    }

    var allSessionRows: [NotchSessionRow] {
        var rows: [String: NotchSessionRow] = [:]
        let notices = sessionNotices.filter {
            $0.disposition == .pending && ($0.needsHighlight || heldNoticeIDs.contains($0.id))
        }
        for notice in notices.sorted(by: {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority < $1.kind.priority }
            if ($0.viewedAt == nil) != ($1.viewedAt == nil) { return $0.viewedAt == nil }
            return $0.began == $1.began ? $0.id < $1.id : $0.began > $1.began
        }) {
            let live = sessions.first {
                $0.source == notice.source && noticeSessionIDs[$0.id] == notice.sessionID
            }
            let target = SessionDetailTarget(source: notice.source, noticeSessionID: notice.sessionID, liveHash: live?.key)
            guard rows[target.id] == nil else { continue }
            let stale = notice.isStale(now: now) || restoredNoticeIDs.contains(notice.id)
            rows[target.id] = NotchSessionRow(target: target, signal: SessionSignal(notice.kind),
                title: notice.kind.title,
                detail: "Last reported \(relative(notice.observedAt))\(stale ? "; stale" : "")" +
                    (notice.kind.isRequest ? "; response unknown" : ""),
                notice: notice, date: notice.began)
        }
        for session in sessions {
            let target = SessionDetailTarget(source: session.source,
                noticeSessionID: noticeSessionIDs[session.id] ?? session.key, liveHash: session.key)
            guard rows[target.id] == nil else { continue }
            let signal: SessionSignal
            let title: String
            let detail: String
            if session.isWorking(now: now) {
                signal = .working
                title = "Working"
                let seconds = max(0, Int(now.timeIntervalSince(session.workStartedAt ?? session.observedAt)))
                detail = seconds < 60 ? "Observed for \(seconds)s" : "Observed for \(seconds / 60)m"
            } else if session.hasMissingActivity(now: now) {
                signal = .unknown
                title = "Activity updates missing"
                detail = "Last reported \(relative(session.observedAt))"
            } else if session.kind == .idle || session.kind == .started {
                signal = session.kind == .idle ? .idle : .unknown
                title = session.kind == .idle ? "Idle" : "Awaiting activity report"
                detail = "Last reported \(relative(session.observedAt))"
            } else { continue }
            rows[target.id] = NotchSessionRow(target: target, signal: signal, title: title,
                detail: detail, notice: nil, date: session.observedAt)
        }
        return rows.values.sorted {
            if $0.signal.priority != $1.signal.priority { return $0.signal.priority < $1.signal.priority }
            let a = $0.notice?.viewedAt == nil && $0.notice != nil
            let b = $1.notice?.viewedAt == nil && $1.notice != nil
            if a != b { return a }
            return $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }

    var activityCoverage: String? {
        guard staleSessionCount > 0 else { return nil }
        return "\(staleSessionCount) \(staleSessionCount == 1 ? "session" : "sessions") without recent updates"
    }

    var clientCounts: String? {
        guard !working.isEmpty else { return nil }
        return "CLI \(working.filter { $0.source == .cli }.count) / VS Code \(working.filter { $0.source == .vscode }.count)"
    }

    var attentions: [NotchAttention] {
        var result: [NotchAttention] = []
        if healthIncident, let date = healthObservedAt, Self.fresh(date, now: now) {
            result.append(NotchAttention(title: "Copilot service incident", session: nil, sessionID: nil,
                                         priority: 3, date: date))
        }
        return result.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.date != $1.date { return $0.date > $1.date }
            return ($0.sessionID ?? "") < ($1.sessionID ?? "")
        }
    }

    var primaryQuota: CopilotQuota? { account?.primaryQuota }

    /// The fraction spent, which is what the ring draws and what the card now
    /// says in words. Nil when there is nothing to divide: no reading, or an
    /// entitlement with no ceiling to be a fraction of.
    var usedFraction: Double? {
        guard let quota = primaryQuota, !quota.isUnlimitedEntitlement else { return nil }
        return min(max(1 - quota.remainingPercentage / 100, 0), 1)
    }

    var quotaWarning: String? {
        guard !accountStale, let account else { return nil }
        let finite = account.quotas.filter { !$0.isUnlimitedEntitlement }
        if let exhausted = finite.first(where: { $0.remainingPercentage == 0 }) {
            return "\(exhausted.title): reported allowance exhausted"
        }
        // Reads the palette's own threshold, so the warning appears on exactly
        // the reading that turns the ring amber.
        let watch = (1 - Palette.watchThreshold) * 100
        if let low = finite.first(where: { $0.remainingPercentage <= watch }) {
            return "\(low.title): near reported limit"
        }
        return nil
    }

    var needsAttention: Bool {
        sessionNotices.contains { $0.kind != .stopped && $0.needsHighlight } ||
            !attentions.isEmpty || quotaWarning != nil
    }

    var usageSource: NotchUsageSource {
        if historyError != nil { return .unavailable }
        if historyLoading { return .loading }
        if savedUsage != nil { return .saved }
        return range == .today ? .live : .needsHistory
    }

    var usageTotals: HistoryTotals? {
        switch usageSource {
        case .saved: return savedUsage?.totals
        case .live:
            guard let tokens else { return nil }
            var totals = HistoryTotals()
            totals.input = tokens.input; totals.output = tokens.output
            totals.cacheInput = tokens.cacheInput; totals.calls = Int64(tokens.calls)
            totals.cacheReportedCalls = tokens.cacheReportedCalls
            totals.cacheUnreportedCalls = tokens.cacheUnreportedCalls
            totals.cacheWrite = tokens.cacheWrite
            totals.cacheWriteReportedCalls = tokens.cacheWriteReportedCalls
            totals.cacheWriteUnreportedCalls = tokens.cacheWriteUnreportedCalls
            return totals
        default: return nil
        }
    }

    var usageTimeline: UsageTimeline? {
        switch usageSource {
        case .saved: return savedTimeline
        case .live: return liveTimeline
        default: return nil
        }
    }

    var timelineNote: String? {
        guard usageSource == .saved, range == .today, let timeline = savedTimeline,
              let began = timeline.detailBegan, let start = timeline.buckets.first?.interval.start else { return nil }
        if began > start {
            let formatter = timeFormat.formatter(in: TimeZone(identifier: timeline.zone))
            return "Hourly detail since \(formatter.string(from: began))"
        }
        if let totals = usageTotals, totals.total != timeline.total || totals.calls != timeline.calls {
            return "Some usage has no hourly detail"
        }
        return nil
    }

    var allModelRows: [NotchModelRow] {
        switch usageSource {
        case .saved: return savedUsage?.models.map(NotchModelRow.init) ?? []
        case .live: return models.map(NotchModelRow.init)
        default: return []
        }
    }

    var canExpandModels: Bool { allModelRows.filter(\.isNamed).count > 3 }

    var modelRows: [NotchModelRow] {
        let all = allModelRows
        let named = all.filter(\.isNamed).sorted {
            $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens
        }
        var rows = modelsExpanded ? named : Array(named.prefix(3))
        let shown = Set(rows.map(\.id))
        let rest = all.filter { !shown.contains($0.id) }
        if !rest.isEmpty {
            let unknown = rest.contains { $0.model == "" || $0.model == "*" }
            rows.append(NotchModelRow(model: nil, title: unknown ? "Other / unavailable models" : "Remaining models",
                input: rest.reduce(0) { $0 + $1.input },
                output: rest.reduce(0) { $0 + $1.output },
                cacheInput: rest.reduce(0) { $0 + $1.cacheInput },
                calls: rest.reduce(0) { $0 + $1.calls },
                cacheReportedCalls: rest.reduce(0) { $0 + $1.cacheReportedCalls },
                cacheUnreportedCalls: rest.reduce(0) { $0 + $1.cacheUnreportedCalls },
                cacheWrite: rest.reduce(0) { $0 + $1.cacheWrite },
                cacheWriteReportedCalls: rest.reduce(0) { $0 + $1.cacheWriteReportedCalls },
                cacheWriteUnreportedCalls: rest.reduce(0) { $0 + $1.cacheWriteUnreportedCalls },
                unverifiedCalls: rest.reduce(0) { $0 + $1.unverifiedCalls }))
        }
        return rows
    }

    var provenance: String {
        if usageSource == .saved {
            return historyRecording ? "Usage data saved locally" : "Saved locally; recording paused"
        }
        return tokensPartial ? "Live only; sample limit reached" : "Live usage only; not saved"
    }

    var sourceDetails: String {
        if let savedUsage, usageSource == .saved {
            let days = savedUsage.days.filter { $0.tokens.calls > 0 }.count
            let coverage = range == .week ? " Usage recorded on \(days) of 7 days." : ""
            let gaps = savedUsage.days.contains(where: \.gap) ? " Known recording gaps." : ""
            let imported = savedUsage.hasImportedData ? " Includes imported observations, not continuous recording." : ""
            return "\(savedUsage.zone). Archive began \(savedUsage.began.formatted()). Partial local usage coverage.\(coverage) Today is incomplete. Missing dates are unknown, not zero.\(gaps)\(imported) Not account-wide usage or billing."
        }
        return "\(TimeZone.current.identifier). Today's retained \(metricSource?.title ?? "all-source") samples, up to 4,096 calls in 24-hour memory. Partial local usage coverage. Restart clears live data. Not account-wide usage or billing."
    }

    static func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000_000_000 {
            return value.formatted(.number.notation(.scientific).precision(.fractionLength(0...1)))
        }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func calls(_ value: Int64) -> String {
        "\(value.formatted()) \(value == 1 ? "call" : "calls")"
    }

    func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSince(now)) < 1 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
