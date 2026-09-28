import Foundation
import TokenotchCore

enum HistoryInsightChecks {
    static let now = HistoryChecks.date("2026-09-21T12:00:00Z")

    static func comparison(calls: Int = 25, firstSamples: Int = 20, durationSamples: Int = 25,
                           gap: Bool = false, missingDay: Bool = false, compactions: Bool = true,
                           zeroFirstBaseline: Bool = false, unknown: Bool = false) throws -> HistoryInsightComparison {
        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = HistoryCalendar(zone: TimeZone(secondsFromGMT: 0)!)
        let periods = HistoryInsightComparison.periods(now: now, calendar: calendar)
        let store = try UsageHistoryStore(root: root, zone: calendar.calendar.timeZone, now: periods.1.start)
        for (period, current) in [(periods.1, false), (periods.0, true)] {
            var events: [ActivityEvent] = []
            for index in 0..<calls {
                let offset = index % (missingDay ? 6 : 7)
                let date = calendar.addingDays(offset, to: period.start).addingTimeInterval(60 + Double(index))
                events.append(HistoryChecks.usage("\(current)-\(index)", at: date,
                    model: unknown ? nil : current && index < 15 ? "new-model" : "old-model",
                    first: index < firstSamples ? (current ? 200 : zeroFirstBaseline ? 0 : 100) : nil,
                    duration: index < durationSamples ? (current ? 500 : 1000) : nil))
            }
            if compactions {
                for index in 0..<(current ? 2 : 1) {
                    events.append(ActivityEvent(source: .cli, session: ActivityEvent.digest("fixture"), kind: .compaction,
                        timestamp: period.start.addingTimeInterval(3600),
                        compaction: CompactionUsage(success: index == 0), metricID: ActivityEvent.digest("\(current)-compaction-\(index)")))
                }
                events.append(ActivityEvent(source: .cli, session: ActivityEvent.digest("fixture"), kind: .compaction,
                    timestamp: period.start, compaction: CompactionUsage(success: nil),
                    metricID: ActivityEvent.digest("\(current)-start")))
            }
            try store.record(events, now: period.end)
        }
        if gap { try store.markGap(at: periods.1.start) }
        return try HistoryInsightComparison(current: store.query(periods.0), previous: store.query(periods.1), now: now)
    }

    static func run() throws {
        let value = try comparison()
        func metric(_ kind: HistoryInsightKind, _ comparison: HistoryInsightComparison = value) throws -> HistoryInsight {
            guard let result = comparison.insights.first(where: { $0.kind == kind }) else {
                throw HistoryChecks.Failure(description: "Missing insight")
            }
            return result
        }
        let mix = try metric(.modelMix)
        try HistoryChecks.require(mix.eligible && mix.subject == "new-model" && mix.current == 60 && mix.previous == 0,
                                  "Model share, union or stable tie-break incorrect")
        let first = try metric(.firstToken)
        try HistoryChecks.require(first.eligible && first.current == 200 && first.previous == 100 && first.percentage == 100,
                                  "Exact 20 samples / 80% coverage must qualify")
        try HistoryChecks.require(first.currentSamples == 20 && first.warnings.contains { $0.contains("5 current") },
                                  "Missing latency count not exposed")
        let duration = try metric(.duration)
        try HistoryChecks.require(duration.eligible && duration.currentSamples == 25 && duration.percentage == -50,
                                  "Latency metrics must have independent sample denominators")
        let compaction = try metric(.compaction)
        try HistoryChecks.require(compaction.current == 8 && compaction.previous == 4 && compaction.currentSamples == 2,
                                  "Compaction must include failed completions, exclude starts and divide by calls")
        try HistoryChecks.require(value.evidence(for: first).comparison.id == value.id, "Evidence snapshot identity changed")
        for sparse in [try comparison(gap: true), try comparison(missingDay: true)] {
            try HistoryChecks.require(sparse.insights.allSatisfy { !$0.eligible }, "Sparse/gapped history produced a headline")
        }
        try HistoryChecks.require(try !metric(.modelMix, comparison(calls: 19)).eligible, "19 calls qualified for model mix")
        let belowSamples = try comparison(firstSamples: 19)
        try HistoryChecks.require(try !metric(.firstToken, belowSamples).eligible, "19 samples qualified")
        try HistoryChecks.require(try metric(.duration, belowSamples).eligible, "One missing field disabled another metric")
        let belowCoverage = try comparison(calls: 26, firstSamples: 20)
        try HistoryChecks.require(try !metric(.firstToken, belowCoverage).eligible, "Below 80% coverage qualified")
        let exactCalls = try comparison(calls: 20, firstSamples: 20, durationSamples: 20)
        try HistoryChecks.require(try metric(.modelMix, exactCalls).eligible, "20 calls must qualify")
        let absent = try comparison(compactions: false)
        try HistoryChecks.require(try metric(.compaction, absent).current == nil && !metric(.compaction, absent).eligible,
                                  "No compactions became an observed zero")
        let zero = try comparison(zeroFirstBaseline: true)
        try HistoryChecks.require(try metric(.firstToken, zero).eligible && metric(.firstToken, zero).previous == 0
                                  && metric(.firstToken, zero).percentage == nil, "Zero latency baseline mishandled")
        let unknown = try comparison(unknown: true)
        try HistoryChecks.require(try !metric(.modelMix, unknown).eligible && metric(.modelMix, unknown).currentSamples == 25,
                                  "Missing models invented a named mix or changed the denominator")

        let root = HistoryChecks.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = HistoryCalendar(zone: TimeZone(identifier: "America/New_York")!)
        for date in [HistoryChecks.date("2026-03-15T12:00:00Z"), HistoryChecks.date("2026-11-08T12:00:00Z")] {
            let pair = HistoryInsightComparison.periods(now: date, calendar: clock)
            try HistoryChecks.require(clock.dayCount(pair.0) == 7 && clock.dayCount(pair.1) == 7
                                      && pair.0.end == clock.calendar.startOfDay(for: date), "DST or today boundary incorrect")
        }
        let pair = HistoryInsightComparison.periods(now: now, calendar: clock)
        let store = try UsageHistoryStore(root: root, zone: clock.calendar.timeZone, now: pair.1.start.addingTimeInterval(1))
        for day in 0..<14 {
            let date = clock.addingDays(day, to: pair.1.start).addingTimeInterval(3600)
            let count = day == 13 ? 40 : 3
            try store.record((0..<count).map { index in
                HistoryChecks.usage("weighted-\(day)-\(index)", at: date, first: day == 13 ? 500 : 100, duration: 0)
            }, now: date)
        }
        try store.record([HistoryChecks.usage("today", at: now, first: 50000)], now: now)
        let weighted = try HistoryInsightComparison(current: store.query(pair.0), previous: store.query(pair.1), now: now)
        let expected = Double(40 * 500 + 18 * 100) / 58
        try HistoryChecks.require(try abs((metric(.firstToken, weighted).current ?? 0) - expected) < 0.00001,
                                  "Mean of means or today contaminated weighted evidence")
        try HistoryChecks.require(weighted.insights.allSatisfy { !$0.eligible }, "Mid-window consent qualified")
        let modelsDate = pair.0.start
        try store.record((0..<102).map {
            HistoryChecks.usage("overflow-\($0)", at: modelsDate, model: "many-model-\($0)")
        }, now: modelsDate)
        let overflow = try HistoryInsightComparison(current: store.query(pair.0), previous: store.query(pair.1), now: now)
        try HistoryChecks.require(overflow.current.models.contains { $0.id == "*" }
                                  && overflow.current.models.reduce(Int64(0), { $0 + $1.tokens.calls }) == overflow.current.totals.calls,
                                  "Overflow models escaped the all-call denominator")
        try HistoryChecks.require(try metric(.modelMix, overflow).warnings.contains { $0.contains("detail was combined") },
                                  "Model detail limit not disclosed")
    }
}
