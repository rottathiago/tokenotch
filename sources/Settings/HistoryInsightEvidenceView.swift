import TokenotchCore
import SwiftUI

struct HistoryInsightEvidenceView: View {
    let evidence: HistoryInsightEvidence
    private var comparison: HistoryInsightComparison { evidence.comparison }
    private var insight: HistoryInsight { evidence.insight }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.headline).font(.headline)
                Text("\(period(comparison.currentPeriod)) compared with \(period(comparison.previousPeriod))")
                    .foregroundStyle(.secondary)
                if let subject = insight.subject { Text("Model: \(subject)").foregroundStyle(.secondary) }
            }
            block {
                row("This week", value(insight.current))
                row("Previous week", value(insight.previous))
                if insight.eligible, let difference = insight.difference {
                    row("Difference", String(format: "%+.2f %@", difference,
                        insight.kind == .modelMix ? "percentage points" : insight.unit))
                    if let percentage = insight.percentage {
                        row("Relative change", String(format: "%+.1f%%", percentage))
                    }
                }
                row("Metric samples", "\(insight.currentSamples) / \(insight.previousSamples)")
                row("Model calls", "\(comparison.current.totals.calls) / \(comparison.previous.totals.calls)")
                if insight.kind == .compaction {
                    row("Compactions this week", outcomes(comparison.current))
                    row("Compactions previous week", outcomes(comparison.previous))
                }
            }
            if !insight.reasons.isEmpty || !insight.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(insight.reasons, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution)
                    }
                    ForEach(insight.warnings, id: \.self) {
                        Label($0, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Daily evidence") {
                VStack(alignment: .leading, spacing: 0) {
                    daily(comparison.previous, interval: comparison.previousPeriod)
                    daily(comparison.current, interval: comparison.currentPeriod)
                }
                .padding(.top, 6)
            }
            if insight.kind != .compaction {
                DisclosureGroup("Per-model evidence") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(modelKeys, id: \.self) { key in
                            let current = comparison.current.models.first { $0.id == key }
                            let previous = comparison.previous.models.first { $0.id == key }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(current?.title ?? previous?.title ?? "Model unavailable").fontWeight(.medium)
                                Text("This week: \(modelValue(current?.tokens, total: comparison.current.totals.calls))")
                                Text("Previous: \(modelValue(previous?.tokens, total: comparison.previous.totals.calls))")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            SettingsFootnote("Based on usage recorded on this Mac, in \(comparison.current.zone). Snapshot taken \(comparison.observedAt.formatted(date: .abbreviated, time: .shortened)).")
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var modelKeys: [String] {
        Set(comparison.current.models.map(\.id)).union(comparison.previous.models.map(\.id)).sorted()
    }
    private func value(_ number: Double?) -> String {
        number.map { String(format: "%.2f %@", $0, insight.unit) } ?? "Unavailable"
    }
    private func modelValue(_ totals: HistoryTotals?, total: Int64) -> String {
        guard let totals else { return "No calls observed for this model" }
        switch insight.kind {
        case .modelMix:
            return total > 0 ? String(format: "%lld / %lld calls (%.2f%%)", totals.calls, total,
                                      Double(totals.calls) / Double(total) * 100) : "Unavailable"
        case .firstToken:
            return "\(value(totals.meanFirstToken)); \(totals.firstTokenSamples)/\(totals.calls) calls sampled"
        case .duration:
            return "\(value(totals.meanDuration)); \(totals.durationSamples)/\(totals.calls) calls sampled"
        case .compaction: return "Not model-attributed"
        }
    }
    private func period(_ interval: DateInterval) -> String {
        guard let zone = TimeZone(identifier: comparison.current.zone) else { return "Unavailable reporting zone" }
        let clock = HistoryCalendar(zone: zone)
        return "\(clock.key(interval.start)) - \(clock.key(clock.addingDays(-1, to: interval.end)))"
    }
    private func outcomes(_ snapshot: HistorySnapshot) -> String {
        "\(snapshot.days.reduce(Int64(0)) { $0 + $1.compactions }) completed, \(snapshot.days.reduce(Int64(0)) { $0 + $1.failedCompactions }) failed"
    }
    @ViewBuilder private func daily(_ snapshot: HistorySnapshot, interval: DateInterval) -> some View {
        if let zone = TimeZone(identifier: snapshot.zone) {
            ForEach(HistoryCalendar(zone: zone).keys(interval), id: \.self) { day in
                let value = snapshot.days.first { $0.day == day }
                HStack(alignment: .firstTextBaseline) {
                    Text(day).monospacedDigit()
                    Spacer()
                    if let value {
                        Text("\(value.tokens.calls) calls, \(Int(value.recordingSeconds / 60)) min recorded\(value.gap ? ", interrupted" : "")")
                    } else {
                        Text("Not recorded").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 2)
            }
        }
    }
}
