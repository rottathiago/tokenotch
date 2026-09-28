import Foundation

public enum HistoryInsightKind: String, CaseIterable, Identifiable, Sendable {
    case modelMix, firstToken, duration, compaction
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .modelMix: return "Model mix"
        case .firstToken: return "First-token latency"
        case .duration: return "Call duration"
        case .compaction: return "Compaction frequency"
        }
    }
}

public struct HistoryInsight: Identifiable, Sendable {
    public var id: HistoryInsightKind { kind }
    public let kind: HistoryInsightKind
    public let current: Double?
    public let previous: Double?
    public let currentSamples: Int64
    public let previousSamples: Int64
    public let subject: String?
    public let reasons: [String]
    public let warnings: [String]
    public var eligible: Bool { reasons.isEmpty && current != nil && previous != nil }
    public var difference: Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }
    public var percentage: Double? {
        guard eligible, kind != .modelMix, let current, let previous else { return nil }
        return HistoryCalendar.percentage(current: current, baseline: previous)
    }
    public var unit: String {
        switch kind {
        case .modelMix: return "% of observed calls"
        case .firstToken, .duration: return "ms"
        case .compaction: return "completions / 100 observed calls"
        }
    }
    public var headline: String {
        guard eligible, let difference else { return "\(kind.title): comparison unavailable" }
        let direction = difference > 0 ? "increased" : difference < 0 ? "decreased" : "unchanged"
        if kind == .modelMix {
            return "Observed \(subject ?? "model") call share \(direction)"
        }
        return "Observed \(kind.title.lowercased()) \(direction)"
    }
}

public struct HistoryInsightEvidence: Identifiable, Sendable {
    public let comparison: HistoryInsightComparison
    public let insight: HistoryInsight
    public var id: String { "\(comparison.id):\(insight.id.rawValue)" }
}

public struct HistoryInsightComparison: Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let currentPeriod: DateInterval
    public let previousPeriod: DateInterval
    public let current: HistorySnapshot
    public let previous: HistorySnapshot
    public let insights: [HistoryInsight]

    public static func periods(now: Date, calendar: HistoryCalendar) -> (DateInterval, DateInterval) {
        let end = calendar.calendar.startOfDay(for: now)
        let middle = calendar.addingDays(-7, to: end)
        return (DateInterval(start: middle, end: end),
                DateInterval(start: calendar.addingDays(-7, to: middle), end: middle))
    }

    public init(current: HistorySnapshot, previous: HistorySnapshot, now: Date) throws {
        guard current.zone == previous.zone, let zone = TimeZone(identifier: current.zone) else {
            throw HistoryError.invalid
        }
        id = UUID()
        observedAt = now
        self.current = current
        self.previous = previous
        let calendar = HistoryCalendar(zone: zone)
        let periods = Self.periods(now: now, calendar: calendar)
        currentPeriod = periods.0
        previousPeriod = periods.1
        var common: [String] = []
        let currentDays = current.days.filter { $0.tokens.calls > 0 }.count
        let previousDays = previous.days.filter { $0.tokens.calls > 0 }.count
        if currentDays != 7 || previousDays != 7 {
            common.append("Observed calls on \(currentDays)/7 vs \(previousDays)/7 days; all fourteen days are required.")
        }
        if max(current.began, previous.began) > periods.1.start {
            common.append("Collection began within the comparison window.")
        }
        if (current.days + previous.days).contains(where: \.gap) {
            common.append("Known recording gaps in the comparison window.")
        }
        let a = current.totals, b = previous.totals
        let modelsA = Dictionary(uniqueKeysWithValues: current.models.map { ($0.id, $0.tokens) })
        let modelsB = Dictionary(uniqueKeysWithValues: previous.models.map { ($0.id, $0.tokens) })
        let keys = Set(modelsA.keys).union(modelsB.keys)
        func share(_ counts: [String: HistoryTotals], _ key: String, _ calls: Int64) -> Double {
            calls > 0 ? Double(counts[key]?.calls ?? 0) / Double(calls) * 100 : 0
        }
        let subject = keys.filter { !$0.isEmpty && $0 != "*" }.sorted {
            let left = abs(share(modelsA, $0, a.calls) - share(modelsB, $0, b.calls))
            let right = abs(share(modelsA, $1, a.calls) - share(modelsB, $1, b.calls))
            return left == right ? $0 < $1 : left > right
        }.first
        var mixReasons = common
        if a.calls < 20 || b.calls < 20 { mixReasons.append("Model mix needs at least 20 observed calls in each period.") }
        if subject == nil { mixReasons.append("Named model observations unavailable.") }
        var mixWarnings = ["Shares include all observed calls, not tokens. Missing model entries are not proof of no model use."]
        if keys.contains("") { mixWarnings.append("Some calls have no model identifier; they remain in the denominator.") }
        if keys.contains("*") { mixWarnings.append("Some model detail was combined at the archive limit; named-model shares may be incomplete.") }
        var results = [HistoryInsight(kind: .modelMix,
            current: subject.flatMap { a.calls > 0 ? share(modelsA, $0, a.calls) : nil },
            previous: subject.flatMap { b.calls > 0 ? share(modelsB, $0, b.calls) : nil },
            currentSamples: a.calls, previousSamples: b.calls, subject: subject,
            reasons: mixReasons, warnings: mixWarnings)]
        for kind in [HistoryInsightKind.firstToken, .duration] {
            let countA = kind == .firstToken ? a.firstTokenSamples : a.durationSamples
            let countB = kind == .firstToken ? b.firstTokenSamples : b.durationSamples
            guard countA >= 0, countB >= 0, countA <= a.calls, countB <= b.calls else { throw HistoryError.invalid }
            var reasons = common
            if countA < 20 || countB < 20 { reasons.append("This metric needs at least 20 valid samples in each period.") }
            if a.calls == 0 || b.calls == 0 || Double(countA) / Double(max(1, a.calls)) < 0.8
                || Double(countB) / Double(max(1, b.calls)) < 0.8 {
                reasons.append("This field needs at least 80% coverage of observed calls in each period.")
            }
            results.append(HistoryInsight(kind: kind,
                current: kind == .firstToken ? a.meanFirstToken : a.meanDuration,
                previous: kind == .firstToken ? b.meanFirstToken : b.meanDuration,
                currentSamples: countA, previousSamples: countB, subject: nil, reasons: reasons,
                warnings: ["Missing field on \(a.calls - countA) current / \(b.calls - countB) previous calls.",
                           "Means are weighted by valid samples. Changed model mix can affect latency; this is not evidence of causation."]))
        }
        func completions(_ snapshot: HistorySnapshot) throws -> Int64 {
            var total: Int64 = 0
            for day in snapshot.days {
                for count in [day.compactions, day.failedCompactions] {
                    let (next, overflow) = total.addingReportingOverflow(count)
                    guard count >= 0, !overflow else { throw HistoryError.invalid }
                    total = next
                }
            }
            return total
        }
        let completionsA = try completions(current), completionsB = try completions(previous)
        var reasons = common
        if completionsA == 0 || completionsB == 0 || a.calls == 0 || b.calls == 0 {
            reasons.append("Both periods need observed compaction completions and calls; no completions observed does not establish zero.")
        }
        results.append(HistoryInsight(kind: .compaction,
            current: a.calls > 0 && completionsA > 0 ? Double(completionsA) / Double(a.calls) * 100 : nil,
            previous: b.calls > 0 && completionsB > 0 ? Double(completionsB) / Double(b.calls) * 100 : nil,
            currentSamples: completionsA, previousSamples: completionsB, subject: nil, reasons: reasons,
            warnings: ["Successful and failed completions are counted once; starts are excluded.",
                       "Compactions are not model-attributed. Missing event delivery is unknown, not zero."]))
        insights = results
    }

    public func evidence(for insight: HistoryInsight) -> HistoryInsightEvidence {
        HistoryInsightEvidence(comparison: self, insight: insight)
    }
}
