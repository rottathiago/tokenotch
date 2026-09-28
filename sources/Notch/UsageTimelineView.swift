import TokenotchCore
import SwiftUI

struct UsageTimelineView: View {
    let timeline: UsageTimeline
    let now: Date
    var scale: CGFloat = 1
    var timeFormat: TimeFormat = .twentyFourHour

    var horizontalInset: CGFloat {
        (timeline.granularity == .hour && timeFormat == .twelveHour
            ? NotchLayout.timelineMeridiemInset : NotchLayout.timelineInset) * scale
    }

    var displayedBuckets: [UsageBucket] {
        timeline.granularity == .hour
            ? timeline.buckets.filter { $0.interval.start <= now }
            : timeline.buckets
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2 * scale) {
            ForEach(displayedBuckets) { bucket in
                let description = detail(for: bucket)
                VStack(spacing: 3 * scale) {
                    GeometryReader { proxy in
                        let height = barHeight(for: bucket)
                        ZStack(alignment: .bottom) {
                            Color.clear
                            if bucket.tokens > 0 {
                                RoundedRectangle(cornerRadius: scale)
                                    .fill(Palette.primary)
                                    .frame(width: min(proxy.size.width, 18 * scale), height: height)
                            } else {
                                emptyMark(for: bucket)
                            }
                        }
                    }
                    .frame(height: NotchLayout.timelineHeight * scale)
                    Text(" ")
                        .font(Typography(scale: scale).cardCaption)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            Text(tick(for: bucket))
                                .font(Typography(scale: scale).cardCaption)
                                .foregroundStyle(Palette.secondary)
                                .fixedSize()
                        }
                    Capsule()
                        .fill(bucket.isCurrent(at: now) ? Palette.primary : .clear)
                        .frame(width: 3 * scale, height: 1.5 * scale)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help(description)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(description)
            }
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Observed tokens by \(timeline.granularity == .hour ? "hour" : "day")")
        .accessibilityHint("Partial local observations, not account-wide usage or cost. Bar heights are relative to this period's maximum.")
    }

    func barHeight(for bucket: UsageBucket) -> CGFloat {
        guard bucket.tokens > 0, timeline.maximum > 0 else { return 0 }
        return max(scale, CGFloat(Double(bucket.tokens) / Double(timeline.maximum)) * NotchLayout.timelineHeight * scale)
    }

    @ViewBuilder private func emptyMark(for bucket: UsageBucket) -> some View {
        switch bucket.coverage(at: now) {
        case .future:
            EmptyView()
        case .unavailable:
            Circle().fill(Palette.secondary).frame(width: 2 * scale, height: 2 * scale)
        case .partial:
            RoundedRectangle(cornerRadius: scale).strokeBorder(Palette.secondary, lineWidth: scale)
                .frame(width: 5 * scale, height: 3 * scale)
        case .recorded:
            Capsule().fill(Palette.secondary).frame(width: 5 * scale, height: scale)
        }
    }

    func tick(for bucket: UsageBucket) -> String {
        let formatter = timeFormat.formatter(in: TimeZone(identifier: timeline.zone))
        if timeline.granularity == .day {
            formatter.dateFormat = "EEE"
            return formatter.string(from: bucket.interval.start)
        }
        let hour = formatter.calendar.dateComponents(in: formatter.timeZone, from: bucket.interval.start).hour ?? 0
        guard hour.isMultiple(of: 6) || bucket.isCurrent(at: now) else { return " " }
        // Leave room for AM/PM beside the current-hour label in dense plots.
        if timeFormat == .twelveHour, !bucket.isCurrent(at: now),
           displayedBuckets.count > 12,
           let index = displayedBuckets.firstIndex(where: { $0.id == bucket.id }),
           let current = displayedBuckets.firstIndex(where: { $0.isCurrent(at: now) }),
           current - index < 3 {
            return " "
        }
        formatter.dateFormat = timeFormat.hourPattern
        return formatter.string(from: bucket.interval.start)
    }

    func detail(for bucket: UsageBucket) -> String {
        let formatter = timeFormat.formatter(in: TimeZone(identifier: timeline.zone))
        formatter.dateFormat = timeline.granularity == .hour ? "EEE, MMM d, \(timeFormat.timePattern) zzz" : "EEEE, MMM d, yyyy"
        var interval = formatter.string(from: bucket.interval.start)
        if timeline.granularity == .hour {
            formatter.dateFormat = "\(timeFormat.timePattern) zzz"
            interval += " to \(formatter.string(from: bucket.interval.end))"
        }
        let value: String
        switch bucket.coverage(at: now) {
        case .future: value = "Future interval; no observations yet."
        case .unavailable: value = "No observations available; not zero usage."
        case .partial:
            value = "\(bucket.tokens.formatted()) observed tokens, \(NotchPresentation.calls(bucket.calls)). Partial recording coverage."
        case .recorded:
            value = "\(bucket.tokens.formatted()) observed tokens, \(NotchPresentation.calls(bucket.calls)). Recording opportunity covered this interval, not proof of complete Copilot coverage."
        }
        return "\(interval): \(value)\(bucket.isCurrent(at: now) ? " In progress." : "")\(bucket.legacy ? " Includes legacy accounting; input/cache overlap may be present." : "")"
    }
}
