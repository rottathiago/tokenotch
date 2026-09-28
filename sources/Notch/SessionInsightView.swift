import TokenotchCore
import SwiftUI

struct SessionContextMeter: View {
    let context: ObservedContext?
    let source: Client
    let now: Date
    var scale: CGFloat = 1
    var onNotch = false

    var value: String {
        guard let context else { return "Not reported" }
        return MetricFormat.percent(context.usage.fraction) + (context.isStale(now: now) ? " (stale)" : "")
    }

    var details: String {
        guard let context else {
            return source == .cli
                ? "Context not reported. Waiting for a current CLI reading; no usage or model limit is assumed."
                : "Context not reported. VS Code telemetry does not expose context-window occupancy."
        }
        return "\(context.usage.currentTokens.formatted()) of \(context.usage.tokenLimit.formatted()) context tokens (\(value)). " +
            "Last reported \(context.observedAt.formatted(date: .omitted, time: .standard)). " +
            "Current context, not cumulative session tokens."
    }

    var body: some View {
        let stale = context?.isStale(now: now) == true
        let secondary = onNotch ? Palette.secondary : Color.secondary
        VStack(alignment: .leading, spacing: 2 * scale) {
            HStack(spacing: 6 * scale) {
                Text("Context")
                Spacer(minLength: 0)
                Text(value).monospacedDigit()
            }
            .foregroundStyle(secondary)
            if let context {
                MeterBar(fraction: context.usage.fraction,
                         color: stale ? secondary : (onNotch ? Palette.usage(context.usage.fraction)
                                                    : SettingsStyle.usage(context.usage.fraction)),
                         height: 4 * scale)
            } else {
                Capsule().strokeBorder(secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(height: 4 * scale)
                    .accessibilityHidden(true)
            }
        }
        .font(onNotch ? Typography(scale: scale).cardCaption : .caption)
        .help(details)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context")
        .accessibilityValue(details)
    }
}

struct SessionInsightView: View {
    let insight: SessionInsight
    let now: Date

    var body: some View {
        LabeledContent {
            SessionContextMeter(context: insight.context, source: .cli, now: now)
                .frame(width: 200)
        } label: {
            Text("Context window")
            if let context = insight.context {
                Text("\(context.usage.currentTokens.formatted()) of \(context.usage.tokenLimit.formatted()) tokens")
            }
        }
        if let label = insight.compactionLabel(now: now) {
            LabeledContent("Compaction") {
                if let before = insight.compaction?.before, let after = insight.compaction?.after {
                    Text("\(label): \(MetricFormat.tokens(before)) → \(MetricFormat.tokens(after))").monospacedDigit()
                } else {
                    Text(label)
                }
            }
        }
        if let latency = insight.latency, let date = insight.latencyAt {
            let stale = now.timeIntervalSince(date) > 300
            LabeledContent("Last call") {
                Text("First token \(MetricFormat.latency(latency.timeToFirstTokenMs)), total \(MetricFormat.latency(latency.durationMs))")
                    .monospacedDigit()
            }
            .opacity(stale ? 0.6 : 1)
        }
    }
}
