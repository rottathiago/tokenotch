import SwiftUI
import TokenotchCore

struct ClaudeQuotaMeter: View {
    let quota: ClaudeQuotaWindow
    let observedAt: Date
    let now: Date
    var scale: CGFloat = 1
    var onNotch = false

    private var stale: Bool { quota.isStale(observedAt: observedAt, now: now) }
    private var secondary: Color { onNotch ? Palette.secondary : .secondary }
    private var color: Color {
        stale ? secondary : (onNotch ? Palette.usage(quota.fraction) : SettingsStyle.usage(quota.fraction))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.title).foregroundStyle(secondary)
                Spacer(minLength: 4 * scale)
                Text("\(quota.usedPercentage.formatted(.number.precision(.fractionLength(0...1))))% used")
                    .monospacedDigit().foregroundStyle(color)
            }
            MeterBar(fraction: quota.fraction, color: color, height: 4 * scale)
            HStack(alignment: .firstTextBaseline) {
                if stale { Text("Stale reading").foregroundStyle(color) }
                if quota.resetsAt > now {
                    Text("Resets \(quota.resetsAt.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Reset time passed; waiting for Claude")
                }
            }
            .foregroundStyle(secondary)
            .help("Reported reset: \(quota.resetsAt.formatted(date: .abbreviated, time: .standard))")
        }
        .font(onNotch ? Typography(scale: scale).cardSecondary : .callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quota.title), \(quota.usedPercentage.formatted()) percent used\(stale ? ", stale" : ""). Reported reset \(quota.resetsAt.formatted(date: .abbreviated, time: .standard))")
    }
}
