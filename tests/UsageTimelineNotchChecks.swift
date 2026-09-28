import AppKit
import Foundation
import TokenotchCore
import SwiftUI
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum UsageTimelineNotchChecks {
    static func run(directory: URL? = nil) throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-24T14:15:00Z")!
        let clock = HistoryCalendar(zone: TimeZone(secondsFromGMT: 0)!)
        let start = clock.calendar.startOfDay(for: now)
        var ledger = TokenLedger()
        for (hour, count) in [(7, 200), (9, 500), (10, 300), (14, 100)] {
            let date = start.addingTimeInterval(Double(hour) * 3600)
            try ledger.observe(event(at: date, tokens: Int64(count)), now: date)
        }
        let hourly = ledger.hourlyTimeline(now: now, calendar: clock.calendar)
        var live = NotchPresentation(account: try NotchChecks.account(), tokens: ledger.today(now: now, calendar: clock.calendar),
                                     now: now, models: ledger.todayByModel(now: now, calendar: clock.calendar))
        live.liveTimeline = hourly
        try NotchChecks.require(live.usageTimeline == hourly, "Today did not use live-only hourly data")
        var unavailable = live
        unavailable.range = .week
        try NotchChecks.require(unavailable.usageTimeline == nil, "Live data became a seven-day chart")
        unavailable.range = .today
        unavailable.historyLoading = true
        try NotchChecks.require(unavailable.usageTimeline == nil, "Loading exposed a live chart")
        unavailable.historyLoading = false
        unavailable.historyError = "Fixture failure"
        try NotchChecks.require(unavailable.usageTimeline == nil, "Storage failure silently fell back to live")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-chart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, zone: clock.calendar.timeZone, now: clock.addingDays(-6, to: start))
        for (day, count) in [(-6, 100), (-5, 300), (-3, 600), (-2, 400), (0, 200)] {
            let date = clock.addingDays(day, to: now)
            try store.record([event(at: date, tokens: Int64(count))], now: date)
        }
        let snapshot = try store.query(clock.interval(.week, selected: now, now: now))
        let daily = try UsageTimeline.week(snapshot: snapshot, now: now)
        var saved = live
        saved.range = .week
        saved.savedUsage = snapshot
        saved.savedTimeline = daily
        try NotchChecks.require(saved.usageTimeline == daily && daily.total == snapshot.totals.total,
                               "Saved timeline mixed with live counts")
        saved.range = .today
        saved.savedUsage = try store.query(clock.interval(.today, selected: now, now: now))
        let savedHours = try store.hourlyTimeline(now: now)
        saved.savedTimeline = savedHours
        try NotchChecks.require(saved.usageTimeline == savedHours && saved.usageTimeline != hourly,
                               "Saved Today fell back to live samples")
        saved.savedTimeline = UsageTimeline(granularity: .hour, buckets: savedHours.buckets, zone: savedHours.zone,
                                           detailBegan: start.addingTimeInterval(12 * 3600))
        try NotchChecks.require(saved.timelineNote == "Hourly detail since 12:00", "Midday detail start not disclosed")
        saved.timeFormat = .twelveHour
        try NotchChecks.require(saved.timelineNote == "Hourly detail since 12:00 PM", "Coverage note ignored the clock preference")
        saved.savedTimeline = UsageTimeline(granularity: .hour, buckets: hourly.buckets.map { UsageBucket(interval: $0.interval) },
                                           zone: savedHours.zone, detailBegan: start)
        try NotchChecks.require(saved.timelineNote != nil, "Unreconciled hourly/daily totals concealed")

        let chart = UsageTimelineView(timeline: hourly, now: now)
        try NotchChecks.require(chart.displayedBuckets == Array(hourly.buckets.prefix(15)),
                               "Today must retain every elapsed hour, including missing observations, without future space")
        try NotchChecks.require(chart.tick(for: hourly.buckets[14]) == "14", "Today's current-hour endpoint is not labeled")
        try NotchChecks.require(chart.detail(for: hourly.buckets[0]).contains("not zero usage"), "Missing hour announced as zero")
        try NotchChecks.require(chart.detail(for: hourly.buckets[14]).contains("In progress"), "Current hour not marked")
        try NotchChecks.require(chart.detail(for: hourly.buckets[15]).contains("Future interval"), "Future hour ambiguous")
        try NotchChecks.require(chart.detail(for: hourly.buckets[9]).contains("500 observed tokens"), "Exact hover/AX count missing")
        try NotchChecks.require(chart.barHeight(for: hourly.buckets[7]) == NotchLayout.timelineHeight * 0.4
                               && chart.barHeight(for: hourly.buckets[9]) == NotchLayout.timelineHeight
                               && chart.barHeight(for: hourly.buckets[0]) == 0, "Chart is not zero-based linear")
        let weekChart = UsageTimelineView(timeline: daily, now: now)
        try timeFormats(hourly: hourly, daily: daily, now: now, directory: directory)
        try NotchChecks.require(weekChart.displayedBuckets == daily.buckets, "Seven-day chart layout changed")
        try NotchChecks.require(weekChart.detail(for: daily.buckets[6]).contains("In progress")
                               && weekChart.detail(for: daily.buckets[2]).contains("No observations"), "Daily coverage labels")
        let fallback = HistoryCalendar(zone: TimeZone(identifier: "America/New_York")!)
        let fallbackDate = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        let fallbackHours = fallback.hours(on: fallbackDate).map { UsageBucket(interval: $0) }
        let fallbackChart = UsageTimelineView(timeline: UsageTimeline(granularity: .hour, buckets: fallbackHours,
            zone: fallback.calendar.timeZone.identifier), now: fallbackDate)
        try NotchChecks.require(fallbackChart.detail(for: fallbackHours[1]) != fallbackChart.detail(for: fallbackHours[2]),
                               "Repeated hours have identical accessible labels")
        for (date, count) in [("2026-03-08T23:15:00-04:00", 23), ("2026-11-01T23:15:00-05:00", 25)] {
            let time = ISO8601DateFormatter().date(from: date)!
            let buckets = fallback.hours(on: time).map { UsageBucket(interval: $0) }
            let timeline = UsageTimeline(granularity: .hour, buckets: buckets, zone: fallback.calendar.timeZone.identifier)
            let view = UsageTimelineView(timeline: timeline, now: time)
            try NotchChecks.require(view.displayedBuckets.count == count && view.displayedBuckets == buckets,
                                   "Today must preserve short/long daylight-saving days")
            for scale: CGFloat in [0.75, 1, 1.5] {
                try centeredWhiteBars(timeline: timeline, now: time, scale: scale)
                for format in TimeFormat.allCases {
                    try tickLayout(UsageTimelineView(timeline: timeline, now: time, scale: scale, timeFormat: format))
                }
            }
        }
        for timeline in [hourly, daily] {
            for scale: CGFloat in [0.75, 1, 1.5] {
                try centeredWhiteBars(timeline: timeline, now: now, scale: scale)
            }
        }
        for hour in [0, 1, 6, 12, 18, 23] {
            let time = start.addingTimeInterval(Double(hour) * 3600 + 900)
            let view = UsageTimelineView(timeline: hourly, now: time)
            try NotchChecks.require(view.displayedBuckets == Array(hourly.buckets.prefix(hour + 1)),
                                   "Today's display must advance through the current hour")
            for scale: CGFloat in [0.75, 1, 1.5] {
                try centeredWhiteBars(timeline: hourly, now: time, scale: scale)
            }
        }

        var weekly = live
        weekly.range = .week
        weekly.savedUsage = snapshot
        weekly.savedTimeline = daily
        var savedToday = live
        savedToday.savedUsage = try store.query(clock.interval(.today, selected: now, now: now))
        savedToday.savedTimeline = savedHours
        let fixtures = [("hourly", live), ("saved-hourly", savedToday), ("daily", weekly), ("unavailable", unavailable)]
            .flatMap { name, data in
                TimeFormat.allCases.map { format in
                    var formatted = data
                    formatted.timeFormat = format
                    return ("\(name)-\(format.rawValue)", formatted)
                }
            }
        for (name, data) in fixtures {
            for scale: CGFloat in [0.75, 1, 1.5] {
                let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
                let content = CopilotSummaryContent(presentation: data, scale: scale, openClient: { _ in }, openHistory: {})
                    .frame(width: width)
                let size = NSHostingView(rootView: content).fittingSize
                try NotchChecks.require(abs(size.width - width) < 1, "Chart expanded the card width")
                let height = size.height + NotchLayout.cardChrome(scale: scale)
                try NotchChecks.require(height <= 560 * scale, "Chart exceeded normal card height budget")
                let image = try NotchChecks.image(content.padding(NotchLayout.cardPadding * scale).background(Palette.surface))
                try NotchChecks.save(image, name: "timeline-\(name)-\(scale)", directory: directory)
                for edge in NotchEdge.allCases {
                    let placement = NotchCardPlacement(notch: CGRect(x: 400, y: 200, width: 70, height: 200),
                        ringCenter: CGPoint(x: 435, y: 300), edge: edge,
                        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 350), contentHeight: height, scale: scale)
                    try NotchChecks.require(placement.frame.height <= 350, "Chart escaped cramped display")
                    let card = CopilotSummaryView(presentation: data, placement: placement, openClient: { _ in },
                        openUsage: {}, openSettings: {}, openHistory: {})
                    let bitmap = try NotchChecks.hostedImage(card, size: placement.frame.size)
                    try NotchChecks.save(bitmap, name: "timeline-card-\(name)-\(edge.rawValue)-\(scale)", directory: directory)
                }
            }
        }
    }

    private static func event(at date: Date, tokens: Int64) -> ActivityEvent {
        ActivityEvent(source: .cli, session: ActivityEvent.digest("timeline-fixture"), kind: .usage, timestamp: date,
            tokens: TokenUsage(callID: ActivityEvent.digest("\(date)"), input: tokens, output: 0, model: "fixture-model"))
    }

    private static func timeFormats(hourly: UsageTimeline, daily: UsageTimeline, now: Date, directory: URL?) throws {
        let start = hourly.buckets[0].interval.start
        for format in TimeFormat.allCases {
            for hour in 0..<24 {
                let time = start.addingTimeInterval(Double(hour) * 3600 + 900)
                let bucket = hourly.buckets[hour]
                let expected = format == .twelveHour
                    ? "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
                    : String(format: "%02d", hour)
                let view = UsageTimelineView(timeline: hourly, now: time, timeFormat: format)
                try NotchChecks.require(view.tick(for: bucket) == expected, "Incorrect \(format) tick at hour \(hour)")
                let timeText = format == .twelveHour
                    ? "\(hour % 12 == 0 ? 12 : hour % 12):00 \(hour < 12 ? "AM" : "PM")"
                    : String(format: "%02d:00", hour)
                try NotchChecks.require(view.detail(for: bucket).contains(timeText),
                                       "Tooltip/VoiceOver hour disagrees with the chart")
                for scale: CGFloat in [0.75, 1, 1.5] {
                    let scaled = UsageTimelineView(timeline: hourly, now: time, scale: scale, timeFormat: format)
                    try tickLayout(scaled)
                    if hour == 23 {
                        try centeredWhiteBars(timeline: hourly, now: time, scale: scale, timeFormat: format)
                        let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
                        let image = try NotchChecks.image(scaled.frame(width: width).background(Palette.surface))
                        try NotchChecks.save(image, name: "clock-late-\(format.rawValue)-\(scale)", directory: directory)
                    }
                }
            }
            let week = UsageTimelineView(timeline: daily, now: now, timeFormat: format)
            let baseline = UsageTimelineView(timeline: daily, now: now)
            try NotchChecks.require(daily.buckets.allSatisfy {
                week.tick(for: $0) == baseline.tick(for: $0) && week.detail(for: $0) == baseline.detail(for: $0)
            }, "Clock preference changed daily chart dates or coverage")
        }
        let twelve = UsageTimelineView(timeline: hourly, now: now, timeFormat: .twelveHour)
        try NotchChecks.require(twelve.detail(for: hourly.buckets[23]).contains("to 12:00 AM"),
                               "Midnight interval endpoint must be 12 AM, not 12 PM")
        let offset = UsageTimeline(granularity: .hour, buckets: hourly.buckets, zone: "Asia/Kolkata")
        let offsetView = UsageTimelineView(timeline: offset, now: now, timeFormat: .twelveHour)
        try NotchChecks.require(offsetView.tick(for: hourly.buckets[14]) == "7 PM"
                               && offsetView.detail(for: hourly.buckets[14]).contains("7:30 PM"),
                               "Clock preference must use the chart's reporting zone, including half-hour offsets")
        let fallback = HistoryCalendar(zone: TimeZone(identifier: "America/New_York")!)
        let time = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        let repeated = fallback.hours(on: time).map { UsageBucket(interval: $0) }
        let timeline = UsageTimeline(granularity: .hour, buckets: repeated, zone: fallback.calendar.timeZone.identifier)
        let view = UsageTimelineView(timeline: timeline, now: time, timeFormat: .twelveHour)
        try NotchChecks.require(view.detail(for: repeated[1]).contains("1:00 AM EDT")
                               && view.detail(for: repeated[2]).contains("1:00 AM EST"),
                               "12-hour details must distinguish repeated daylight-saving hours")
    }

    private static func tickLayout(_ chart: UsageTimelineView) throws {
        let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * chart.scale
        let inset = chart.horizontalInset
        let gap = 2 * chart.scale
        let buckets = chart.displayedBuckets
        let slot = (width - 2 * inset - CGFloat(buckets.count - 1) * gap) / CGFloat(buckets.count)
        var right: CGFloat = 0
        for (index, bucket) in buckets.enumerated() {
            let tick = chart.tick(for: bucket)
            guard tick != " " else { continue }
            let label = NSHostingView(rootView: Text(tick).font(Typography(scale: chart.scale).cardCaption).fixedSize())
            let center = inset + slot / 2 + CGFloat(index) * (slot + gap)
            let left = center - label.fittingSize.width / 2
            try NotchChecks.require(left >= right - 0.5, "Chart time labels overlap or escape the leading edge: \(tick)")
            right = center + label.fittingSize.width / 2
            try NotchChecks.require(right <= width + 0.5, "Chart time label escapes the trailing edge: \(tick)")
        }
    }

    private static func centeredWhiteBars(timeline: UsageTimeline, now: Date, scale: CGFloat,
                                          timeFormat: TimeFormat = .twentyFourHour) throws {
        let buckets = timeline.buckets.map { original -> UsageBucket in
            var bucket = original
            let elapsed = timeline.granularity == .day || bucket.interval.start <= now
            bucket.tokens = elapsed ? 100 : 0
            bucket.calls = elapsed ? 1 : 0
            return bucket
        }
        let uniform = UsageTimeline(granularity: timeline.granularity, buckets: buckets, zone: timeline.zone)
        let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
        let chart = UsageTimelineView(timeline: uniform, now: now, scale: scale, timeFormat: timeFormat)
        let bitmap = try NotchChecks.image(chart
            .frame(width: width).background(Palette.surface))
        let pixelScale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let row = Int(NotchLayout.timelineHeight * scale * pixelScale / 2)
        let white = (0..<bitmap.pixelsWide).filter { x in
            guard let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.95 && min(color.redComponent, color.greenComponent, color.blueComponent) > 0.95
        }
        guard let first = white.first, let last = white.last else {
            throw NotchCheckFailure.failed("Chart bars are not white")
        }
        let left = CGFloat(first), right = CGFloat(bitmap.pixelsWide - 1 - last)
        try NotchChecks.require(abs(left - right) <= 2 * pixelScale, "Chart bars are not centered")
        try NotchChecks.require(min(left, right) >= chart.horizontalInset * pixelScale - 1,
                               "Chart lacks balanced horizontal inset")
        let visibleCount = buckets.filter { $0.tokens > 0 }.count
        let plotWidth = width - 2 * chart.horizontalInset - CGFloat(visibleCount - 1) * 2 * scale
        let expectedInk = min(plotWidth / CGFloat(visibleCount), 18 * scale) * CGFloat(visibleCount) * pixelScale
        try NotchChecks.require(CGFloat(white.count) >= expectedInk * 0.85, "Bars must be solid white, not dark or outlined")
    }
}
