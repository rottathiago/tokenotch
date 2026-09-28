import Foundation

public struct HistoryTotals: Equatable, Sendable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheInput: Int64 = 0
    public var cacheReportedCalls: Int64 = 0
    public var cacheUnreportedCalls: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var cacheWriteReportedCalls: Int64 = 0
    public var cacheWriteUnreportedCalls: Int64 = 0
    public var unverifiedCalls: Int64 = 0
    public var calls: Int64 = 0
    public var firstTokenSum: Double = 0
    public var firstTokenSamples: Int64 = 0
    public var durationSum: Double = 0
    public var durationSamples: Int64 = 0
    public var total: Int64 { input + output + cacheInput + cacheWrite }
    public var cacheCoverage: CacheInputCoverage {
        CacheInputCoverage(tokens: cacheInput, calls: calls,
            reportedCalls: cacheReportedCalls, unreportedCalls: cacheUnreportedCalls)
    }
    public var breakdown: TokenBreakdown {
        TokenBreakdown(read: cacheCoverage,
            write: CacheInputCoverage(tokens: cacheWrite, calls: calls,
                reportedCalls: cacheWriteReportedCalls, unreportedCalls: cacheWriteUnreportedCalls, kind: .write),
            unverifiedCalls: unverifiedCalls)
    }
    public var meanFirstToken: Double? { firstTokenSamples > 0 ? firstTokenSum / Double(firstTokenSamples) : nil }
    public var meanDuration: Double? { durationSamples > 0 ? durationSum / Double(durationSamples) : nil }
    public init() {}

    mutating func add(_ other: Self) throws {
        guard cacheCoverage.isValid, other.cacheCoverage.isValid,
              breakdown.write.isValid, other.breakdown.write.isValid,
              (0...calls).contains(unverifiedCalls),
              (0...other.calls).contains(other.unverifiedCalls) else { throw HistoryError.invalid }
        func sum(_ left: Int64, _ right: Int64) throws -> Int64 {
            let (value, overflow) = left.addingReportingOverflow(right)
            guard left >= 0, right >= 0, !overflow else { throw HistoryError.invalid }
            return value
        }
        input = try sum(input, other.input); output = try sum(output, other.output)
        cacheInput = try sum(cacheInput, other.cacheInput)
        cacheReportedCalls = try sum(cacheReportedCalls, other.cacheReportedCalls)
        cacheUnreportedCalls = try sum(cacheUnreportedCalls, other.cacheUnreportedCalls)
        cacheWrite = try sum(cacheWrite, other.cacheWrite)
        cacheWriteReportedCalls = try sum(cacheWriteReportedCalls, other.cacheWriteReportedCalls)
        cacheWriteUnreportedCalls = try sum(cacheWriteUnreportedCalls, other.cacheWriteUnreportedCalls)
        unverifiedCalls = try sum(unverifiedCalls, other.unverifiedCalls)
        calls = try sum(calls, other.calls)
        firstTokenSamples = try sum(firstTokenSamples, other.firstTokenSamples)
        durationSamples = try sum(durationSamples, other.durationSamples)
        _ = try sum(try sum(try sum(input, output), cacheInput), cacheWrite)
        firstTokenSum += other.firstTokenSum; durationSum += other.durationSum
        guard firstTokenSum.isFinite, durationSum.isFinite, firstTokenSum >= 0, durationSum >= 0 else {
            throw HistoryError.invalid
        }
    }
}

public struct HistoryDay: Identifiable, Sendable {
    public var id: String { day }
    public let day: String
    public var tokens = HistoryTotals()
    public var contextMaximum: Double?
    public var compactions: Int64 = 0
    public var failedCompactions: Int64 = 0
    public var recordingSeconds: Double = 0
    public var gap = false
    public var hasContext = false
    public var hasCompaction = false
    public var imported = false
    public init(day: String) { self.day = day }
}

public struct HistoryModel: Identifiable, Sendable {
    public let id: String
    public let tokens: HistoryTotals
    public var title: String {
        id.isEmpty ? "Model unavailable" : id == "*" ? "Other models (detail limit)" : id
    }
    public init(id: String, tokens: HistoryTotals) { self.id = id; self.tokens = tokens }
}

public struct HistorySnapshot: Sendable {
    public let days: [HistoryDay]
    public let models: [HistoryModel]
    public let zone: String
    public let began: Date
    public let bytes: Int64
    public let totals: HistoryTotals
    public var hasImportedData: Bool = false
}

public struct NotchHistorySummary: Sendable {
    public let today: HistoryTotals
    public let recent: HistoryTotals
    public let previous: HistoryTotals
    public let recentSampleDays: Int
    public let previousSampleDays: Int
    public let recentPeriod: String
    public let previousPeriod: String
    public let zone: String
    public let change: Double?
    public let comparisonNote: String?

    public static func interval(now: Date, calendar: HistoryCalendar) -> DateInterval {
        let today = calendar.calendar.startOfDay(for: now)
        return DateInterval(start: calendar.addingDays(-14, to: today),
                            end: calendar.addingDays(1, to: today))
    }

    public init(snapshot: HistorySnapshot, now: Date) throws {
        guard let zone = TimeZone(identifier: snapshot.zone) else { throw HistoryError.invalid }
        let calendar = HistoryCalendar(zone: zone)
        let start = calendar.calendar.startOfDay(for: now)
        let recentStart = calendar.addingDays(-7, to: start)
        let previousStart = calendar.addingDays(-14, to: start)
        let todayKey = calendar.key(start)
        let recentKey = calendar.key(recentStart)
        let previousKey = calendar.key(previousStart)
        var today = HistoryTotals(), recent = HistoryTotals(), previous = HistoryTotals()
        var recentDays = 0, previousDays = 0
        var hasGap = false
        for day in snapshot.days {
            if day.day == todayKey {
                try today.add(day.tokens)
            } else if day.day >= previousKey && day.day < todayKey {
                hasGap = hasGap || day.gap
                if day.day >= recentKey {
                    try recent.add(day.tokens)
                    if day.tokens.calls > 0 { recentDays += 1 }
                } else {
                    try previous.add(day.tokens)
                    if day.tokens.calls > 0 { previousDays += 1 }
                }
            }
        }
        self.today = today
        self.recent = recent
        self.previous = previous
        recentSampleDays = recentDays
        previousSampleDays = previousDays
        recentPeriod = "\(recentKey) - \(calendar.key(calendar.addingDays(-1, to: start)))"
        previousPeriod = "\(previousKey) - \(calendar.key(calendar.addingDays(-1, to: recentStart)))"
        self.zone = snapshot.zone
        if recent.unverifiedCalls > 0 || previous.unverifiedCalls > 0 {
            change = nil
            comparisonNote = "Weekly percentage unavailable for legacy samples."
        } else if recentDays < 7 || previousDays < 7 || snapshot.began > previousStart {
            change = nil
            comparisonNote = "Not enough history for a weekly percentage."
        } else if hasGap {
            change = nil
            comparisonNote = "Recording gaps; weekly percentage unavailable."
        } else {
            change = HistoryCalendar.percentage(current: Double(recent.total), baseline: Double(previous.total))
            comparisonNote = change == nil ? "No percentage baseline (0 observed tokens)." : nil
        }
    }
}

public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", week = "Last 7 days", days30 = "Last 30 days"
    case month = "This month", previousMonth = "Previous month", day = "Choose day", chosenMonth = "Choose month"
    public var id: String { rawValue }
}

public struct HistoryCalendar: Sendable {
    public let calendar: Calendar
    public init(zone: TimeZone) {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        calendar = value
    }
    public func key(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
    public func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    public func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }
    public func interval(_ range: HistoryRange, selected: Date, now: Date) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .today: return DateInterval(start: today, end: addingDays(1, to: today))
        case .week: return DateInterval(start: addingDays(-6, to: today), end: addingDays(1, to: today))
        case .days30: return DateInterval(start: addingDays(-29, to: today), end: addingDays(1, to: today))
        case .month: return calendar.dateInterval(of: .month, for: now)!
        case .previousMonth:
            return calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -1, to: now)!)!
        case .day: return calendar.dateInterval(of: .day, for: selected)!
        case .chosenMonth: return calendar.dateInterval(of: .month, for: selected)!
        }
    }
    public func dayCount(_ interval: DateInterval) -> Int {
        calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
    }
    public func keys(_ interval: DateInterval) -> [String] {
        (0..<max(0, dayCount(interval))).map { key(addingDays($0, to: interval.start)) }
    }
    public func prior(_ interval: DateInterval, monthly: Bool) -> DateInterval {
        if monthly {
            return calendar.dateInterval(of: .month,
                for: calendar.date(byAdding: .month, value: -1, to: interval.start)!)!
        }
        return DateInterval(start: addingDays(-dayCount(interval), to: interval.start), end: interval.start)
    }
    public func completedComparison(_ left: DateInterval, _ right: DateInterval, now: Date,
                                    monthly: Bool = false) -> (DateInterval, DateInterval) {
        let today = calendar.startOfDay(for: now)
        if monthly, left.start == today, left.end > today {
            return (DateInterval(start: today, duration: 0), DateInterval(start: right.start, duration: 0))
        }
        guard left.end > today, left.start < today else { return (left, right) }
        let count = min(dayCount(DateInterval(start: left.start, end: today)), dayCount(right))
        let previous = monthly
            ? DateInterval(start: right.start, end: addingDays(count, to: right.start))
            : DateInterval(start: addingDays(-count, to: right.end), end: right.end)
        return (DateInterval(start: left.start, end: addingDays(count, to: left.start)), previous)
    }
    public static func percentage(current: Double, baseline: Double) -> Double? {
        guard baseline > 0 else { return nil }
        return (current - baseline) / baseline * 100
    }
}

public enum HistoryError: String, Error, LocalizedError {
    case storage = "Usage history could not be saved or read. Recording is paused; existing data was not reset."
    case schema = "This history database needs a newer Tokenotch version. It was left unchanged."
    case invalid = "Usage history contains unsupported data. It was not reset."
    case queueFull = "History recording could not keep up. Recording is paused and this period is partial."
    public var errorDescription: String? { rawValue }
}
