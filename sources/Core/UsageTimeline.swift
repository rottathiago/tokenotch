import Foundation

public struct UsageBucket: Equatable, Identifiable, Sendable {
    public enum Coverage: Equatable, Sendable { case future, unavailable, partial, recorded }

    public var id: Date { interval.start }
    public let interval: DateInterval
    public var tokens: Int64 = 0
    public var calls: Int64 = 0
    public var recordingSeconds: Double = 0
    public var gap = false
    public var legacy = false

    public init(interval: DateInterval) { self.interval = interval }

    public func coverage(at now: Date) -> Coverage {
        if interval.start > now && calls == 0 { return .future }
        guard calls > 0 || recordingSeconds > 0 else { return .unavailable }
        let elapsed = min(interval.end, now).timeIntervalSince(interval.start)
        return !gap && !legacy && elapsed > 0 && recordingSeconds >= elapsed - 0.01
            ? .recorded : .partial
    }

    public func isCurrent(at now: Date) -> Bool {
        interval.start <= now && now < interval.end
    }
}

public struct UsageTimeline: Equatable, Sendable {
    public enum Granularity: Sendable { case hour, day }

    public let granularity: Granularity
    public let buckets: [UsageBucket]
    public let zone: String
    public let detailBegan: Date?
    public var total: Int64 { buckets.reduce(0) { $0 + $1.tokens } }
    public var calls: Int64 { buckets.reduce(0) { $0 + $1.calls } }
    public var maximum: Int64 { buckets.map(\.tokens).max() ?? 0 }

    public init(granularity: Granularity, buckets: [UsageBucket], zone: String, detailBegan: Date? = nil) {
        self.granularity = granularity
        self.buckets = buckets
        self.zone = zone
        self.detailBegan = detailBegan
    }

    public static func week(snapshot: HistorySnapshot, now: Date) throws -> Self {
        guard let zone = TimeZone(identifier: snapshot.zone) else { throw HistoryError.invalid }
        let clock = HistoryCalendar(zone: zone)
        let interval = clock.interval(.week, selected: now, now: now)
        let days = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.day, $0) })
        let buckets = try clock.keys(interval).map { key -> UsageBucket in
            guard let start = clock.date(key) else { throw HistoryError.invalid }
            var bucket = UsageBucket(interval: DateInterval(start: start, end: clock.addingDays(1, to: start)))
            if let day = days[key] {
                bucket.tokens = day.tokens.total
                bucket.calls = day.tokens.calls
                bucket.recordingSeconds = day.recordingSeconds
                bucket.gap = day.gap
                bucket.legacy = day.tokens.unverifiedCalls > 0
            }
            return bucket
        }
        return Self(granularity: .day, buckets: buckets, zone: snapshot.zone)
    }
}

extension HistoryCalendar {
    public func hour(containing date: Date) -> DateInterval {
        let day = calendar.dateInterval(of: .day, for: date)!
        let hour = calendar.dateInterval(of: .hour, for: date)!
        var start = max(day.start, hour.start), end = min(day.end, hour.end)
        // Foundation can round a half-hour DST transition back into the previous offset.
        if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: day.start.addingTimeInterval(-1)),
           transition < day.end {
            if transition <= date { start = max(start, transition) }
            else { end = min(end, transition) }
        }
        return DateInterval(start: start, end: end)
    }

    public func hours(on date: Date) -> [DateInterval] {
        let day = interval(.today, selected: date, now: date)
        var result: [DateInterval] = []
        var cursor = day.start
        while cursor < day.end {
            let end = min(hour(containing: cursor).end, day.end)
            result.append(DateInterval(start: cursor, end: end))
            cursor = end
        }
        return result
    }
}
