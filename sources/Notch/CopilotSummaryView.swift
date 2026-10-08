import TokenotchCore
import SwiftUI

struct CopilotSummaryContent: View {
    let presentation: NotchPresentation
    var scale: CGFloat = 1
    let openClient: (Client) -> Void
    let openHistory: () -> Void
    var selectRange: (HistoryRange) -> Void = { _ in }
    var selectSource: (UsageSource?) -> Void = { _ in }
    var openModel: (String?) -> Void = { _ in }
    var openDetails: () -> Void = {}
    var openAllowance: () -> Void = {}
    var openAttention: (String?) -> Void = { _ in }
    var openConnections: () -> Void = {}
    var toggleModels: () -> Void = {}
    var openSession: (SessionDetailTarget, String?) -> Void = { _, _ in }
    var dismissRequest: (String) -> Void = { _ in }
    var noticeVisibility: (String, Bool) -> Void = { _, _ in }

    private var type: Typography { Typography(scale: scale) }
    private var tight: CGFloat { 4 * scale }
    private var rowStyle: NotchCardButtonStyle { NotchCardButtonStyle(inset: false, scale: scale) }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchLayout.blockSpacing * scale) {
            header
            VStack(alignment: .leading, spacing: tight) {
                sectionHeading("Usage")
                allowance
            }
            rule
            activity
            rule
            usageChart
            rule
            models
        }
        .font(type.cardBody)
        .foregroundStyle(Palette.primary)
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(NotchCardButtonStyle(scale: scale))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8 * scale) {
            CopilotGlyph().fill(Palette.primary, style: FillStyle(eoFill: true))
                .frame(width: NotchLayout.glyphSize * scale, height: NotchLayout.glyphSize * scale)
                .accessibilityHidden(true)
            Text("GitHub Copilot / Copilot CLI").font(type.cardTitle)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(type.cardBody.weight(.semibold))
            .foregroundStyle(Palette.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private var allowance: some View {
        Button(action: openAllowance) {
            VStack(alignment: .leading, spacing: tight) {
                if let quota = presentation.primaryQuota {
                    HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                        Text(headline(quota)).font(type.cardTitle).monospacedDigit()
                            .foregroundStyle(headlineColor)
                        Spacer(minLength: 4 * scale)
                        Text(quota.title).font(type.cardSecondary).foregroundStyle(Palette.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if !quota.isUnlimitedEntitlement, let used = presentation.usedFraction {
                        bar(used: used, label: quota.title)
                    }
                    note(quota)
                } else {
                    Text(presentation.account == nil ? "Connect account for allowance" : "No quota reported")
                    Text(presentation.accountStatus).font(type.cardSecondary)
                        .foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(rowStyle)
        .help(presentation.account.map { "Fetched \(presentation.relative($0.observedAt)). Account request quota, not local tokens. Open full usage." }
              ?? "Open account sign-in in Settings")
    }

    private func headline(_ quota: CopilotQuota) -> String {
        guard !quota.isUnlimitedEntitlement, let used = presentation.usedFraction else { return "Unlimited" }
        return "\(Int((used * 100).rounded()))% used"
    }

    /// Colour only once it means something. Below the watch threshold the
    /// number is plain white, so a coloured headline is always a signal rather
    /// than decoration.
    private var headlineColor: Color {
        guard !presentation.accountStale else { return Palette.secondary }
        guard let used = presentation.usedFraction, used >= Palette.watchThreshold else { return Palette.primary }
        return Palette.usage(used)
    }

    private func bar(used: Double, label: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                Capsule().fill(presentation.accountStale ? Palette.secondary : Palette.usage(used))
                    .frame(width: proxy.size.width * used)
            }
        }
        .frame(height: NotchLayout.barHeight * scale)
        .accessibilityLabel("\(label), \(Int((used * 100).rounded())) percent used")
    }

    // One quiet line, never a stack of them. A warning and its reset date are
    // the two halves of the same question, so they share the row — the warning
    // leading, the reset trailing. Alone, the reset simply starts the line
    // rather than floating against the right edge with nothing to balance.
    @ViewBuilder private func note(_ quota: CopilotQuota) -> some View {
        let reset = quota.reportedReset.flatMap { $0 > presentation.now ? $0 : nil }
        let lead: (String, Color)? = presentation.accountStale
            ? ("Stale account reading", Palette.watch)
            : presentation.quotaWarning.map { ($0, presentation.usedFraction.map(Palette.usage) ?? Palette.watch) }
        if lead != nil || reset != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                if let lead {
                    Text(lead.0).lineLimit(1).truncationMode(.tail).foregroundStyle(lead.1)
                        .help(presentation.accountStale ? presentation.accountStatus : "")
                    Spacer(minLength: 0)
                }
                if let reset {
                    Text("Reported reset \(presentation.relative(reset))")
                        .foregroundStyle(Palette.secondary).layoutPriority(1)
                }
                if lead == nil { Spacer(minLength: 0) }
            }
            .font(type.cardSecondary)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: tight) {
            sectionHeading("Sessions")
            Button(action: openDetails) {
                HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                    Label(presentation.activityTitle, systemImage: presentation.sessionSignal.symbol)
                        .foregroundStyle(presentation.sessionSignal.color)
                    Spacer(minLength: 4 * scale)
                    Text("Details").font(type.cardSecondary).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: NotchLayout.rowHeight * scale, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(rowStyle)
            .help("Counts observed work, not open windows. CLI live activity refreshes every 30 seconds; missing updates are not task completion. Open details.")
            .accessibilityLabel(presentation.clientCounts.map { "\(presentation.activityTitle), \($0)" }
                                ?? presentation.activityTitle)
            .accessibilityHint("Open activity details")
            ForEach(presentation.sessionRows) { row in sessionRow(row) }
            if !presentation.working.isEmpty && presentation.sessionSignal.priority < SessionSignal.stopped.priority {
                Text("\(presentation.working.count) working (last reported)")
                    .font(type.cardSecondary).foregroundStyle(Palette.secondary)
            }
            if let message = presentation.noticeStorageMessage {
                Button(message, action: openDetails).font(type.cardSecondary)
                    .foregroundStyle(Palette.sessionWarning)
            }
            if let coverage = presentation.activityCoverage {
                Button(coverage, action: openConnections)
                    .font(type.cardSecondary).foregroundStyle(Palette.secondary)
                    .help("Open Connections. Update the CLI integration and reload extensions in each existing session.")
            }
            if let attention = presentation.attentions.first {
                Button { openAttention(attention.sessionID) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: tight) {
                        Image(systemName: "exclamationmark.circle")
                        Text(attention.title)
                        if presentation.attentions.count > 1 { Text("+\(presentation.attentions.count - 1)") }
                    }
                    .foregroundStyle(Palette.watch)
                }
                .font(type.cardSecondary)
                .help(attention.sessionID.map { "CLI session \($0.prefix(8)); last observed \(presentation.relative(attention.date))" }
                      ?? "Open GitHub Status")
                .accessibilityLabel(attention.title + (attention.sessionID.map { ", CLI session \($0.prefix(8))" } ?? ""))
            }
        }
    }

    func sessionRow(_ row: NotchSessionRow) -> some View {
        let contextMeter = SessionContextMeter(context: presentation.context(for: row.target),
                                               source: row.target.source, now: presentation.now,
                                               scale: scale, onNotch: true)
        return HStack(spacing: tight) {
            Button { openSession(row.target, row.notice?.id) } label: {
                HStack(spacing: tight) {
                    Image(systemName: row.signal.symbol).foregroundStyle(row.signal.color)
                    VStack(alignment: .leading, spacing: 1 * scale) {
                        HStack(spacing: tight) {
                            Text(row.label).foregroundStyle(Palette.secondary)
                            Text(row.title).foregroundStyle(row.signal.color)
                                .lineLimit(1).truncationMode(.tail)
                            if row.notice?.viewedAt == nil && row.notice != nil {
                                Circle().fill(row.signal.color).frame(width: 4 * scale, height: 4 * scale)
                                    .accessibilityLabel("New update")
                            }
                        }
                        Text(row.detail).foregroundStyle(Palette.secondary).lineLimit(1)
                        contextMeter
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(rowStyle)
            .help("\(row.label): \(row.title). \(row.detail). \(contextMeter.details) Open session details.")
            .accessibilityLabel("\(row.label): \(row.title). \(row.detail). \(contextMeter.details)")
            .accessibilityHint("Open session details")
            if let notice = row.notice, notice.kind.isRequest, notice.disposition == .pending {
                Button { dismissRequest(notice.id) } label: {
                    Image(systemName: "checkmark")
                        .frame(width: NotchLayout.rowHeight * scale, height: NotchLayout.rowHeight * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(rowStyle)
                .help("Dismiss")
                .accessibilityLabel("Dismiss \(row.title.lowercased()) for \(row.label)")
                .accessibilityHint("Dismiss this notice without answering or approving the request.")
                .accessibilityIdentifier("dismiss-request-\(notice.id)")
            }
        }
        .font(type.cardSecondary)
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            if let id = row.notice?.id { noticeVisibility(id, visible) }
        }
        .onDisappear {
            if let id = row.notice?.id { noticeVisibility(id, false) }
        }
        .id(row.notice?.id ?? row.id)
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: tight) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Models' Usage Chart")
                Spacer(minLength: 4 * scale)
                Menu {
                    Button("All sources") { selectSource(nil) }
                    ForEach(UsageSource.allCases) { source in
                        Button(source.title) { selectSource(source) }
                    }
                } label: {
                    Text(presentation.metricSource?.title ?? "All sources")
                        .font(type.cardCaption).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Palette.secondary)
                .accessibilityLabel("Usage source: \(presentation.metricSource?.title ?? "All sources")")
            }
            HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
                if let totals = presentation.usageTotals, totals.calls > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
                        Text("Tokens").foregroundStyle(Palette.secondary)
                        Text(NotchPresentation.compact(totals.total)).monospacedDigit()
                        separator.foregroundStyle(Palette.secondary)
                        Text(NotchPresentation.calls(totals.calls)).monospacedDigit()
                            .foregroundStyle(Palette.secondary)
                    }
                    .font(type.cardSecondary)
                    .help(totals.breakdown.totalDetails)
                    .accessibilityLabel("Total: \(totals.total) observed tokens, \(totals.calls) calls. \(totals.breakdown.totalDetails)")
                }
                Spacer(minLength: 6 * scale)
                period("Today", .today).layoutPriority(1)
                period("Last 7 days", .week).layoutPriority(1)
            }
            .lineLimit(1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chart and model usage period")
            switch presentation.usageSource {
            case .loading:
                Text("Reading saved usage...").foregroundStyle(Palette.secondary)
            case .unavailable:
                Button("History unavailable - open to retry", action: openHistory)
                    .foregroundStyle(Palette.watch)
                    .help(presentation.historyError ?? "History unavailable")
            case .needsHistory:
                Text("Seven-day usage needs local history.").foregroundStyle(Palette.secondary)
                Button("Enable local history...", action: openHistory)
            case .saved, .live:
                if let timeline = presentation.usageTimeline {
                    UsageTimelineView(timeline: timeline, now: presentation.now, scale: scale,
                                      timeFormat: presentation.timeFormat)
                    if let note = presentation.timelineNote {
                        Text(note)
                            .font(type.cardCaption).foregroundStyle(Palette.secondary)
                            .help("Earlier daily totals cannot be reconstructed by hour. The chart contains \(timeline.total.formatted()) observed tokens across \(NotchPresentation.calls(timeline.calls)); the total above includes all saved usage for the period.")
                    }
                } else {
                    Text("No time detail available.").foregroundStyle(Palette.secondary)
                }
                if let totals = presentation.usageTotals, totals.calls > 0 {
                    breakdown(input: totals.input, output: totals.output, coverage: totals.breakdown)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(totals.total) observed tokens, \(totals.calls) calls: \(totals.input) \(totals.breakdown.inputLabel), \(totals.output) output. \(totals.breakdown.details)")
                        .help(totals.breakdown.details)
                }
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: tight) {
            sectionHeading("Models Breakdown")
            switch presentation.usageSource {
            case .loading:
                Text("Reading model details...").foregroundStyle(Palette.secondary)
            case .unavailable, .needsHistory:
                Text("Model details unavailable for this period.").foregroundStyle(Palette.secondary)
            case .saved, .live:
                if let totals = presentation.usageTotals, totals.calls > 0 {
                    ForEach(presentation.modelRows) { row in
                        Button { openModel(row.model) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                tokenLine(title: row.title, total: row.tokens, calls: row.calls)
                                breakdown(input: row.input, output: row.output, coverage: row.breakdown)
                            }
                            .font(type.cardSecondary)
                            .frame(maxWidth: .infinity, minHeight: NotchLayout.rowHeight * scale, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(rowStyle)
                        .help("\(row.title): \(row.tokens.formatted()) observed tokens / \(row.calls.formatted()) calls. \(row.input.formatted()) \(row.breakdown.inputLabel), \(row.output.formatted()) output. \(row.breakdown.details)")
                        .accessibilityLabel("\(row.title), \(row.tokens) observed tokens, \(row.calls) calls, \(row.input) \(row.breakdown.inputLabel), \(row.output) output tokens. \(row.breakdown.details) Open details")
                    }
                    if totals.breakdown.isIncomplete || presentation.modelRows.contains(where: { $0.breakdown.isIncomplete }) {
                        Text("* Some calls did not report cache tokens")
                            .font(type.cardSecondary).foregroundStyle(Palette.secondary)
                            .help("Starred input may include unreported cache activity; starred cache counts cover only the calls that reported them.")
                    }
                    if presentation.canExpandModels { disclosure }
                } else {
                    Text("No samples observed.").foregroundStyle(Palette.secondary)
                    if presentation.usageSource == .live {
                        Button("Connect CLI", action: openConnections)
                    }
                }
            }
        }
    }

    private var disclosure: some View {
        Button(presentation.modelsExpanded ? "Show fewer models" : "Show all models", action: toggleModels)
            .font(type.cardSecondary)
    }

    // The sum leads the row because it is the comparison a reader makes first;
    // the parts it is made of belong underneath it, not beside it, where
    // they used to crowd the model name into a truncated stub.
    private func tokenLine(title: String, total: Int64, calls: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
            Text(title).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Spacer(minLength: 4 * scale)
            Text(NotchPresentation.compact(total)).monospacedDigit().layoutPriority(1)
            separator.foregroundStyle(Palette.secondary)
            Text(NotchPresentation.calls(calls)).monospacedDigit()
                .foregroundStyle(Palette.secondary).layoutPriority(1)
        }
    }

    // Four numbers in a row blur together; a 2×2 grid gives each its own
    // column, and a coloured dot lets the eye find a category without reading.
    func breakdown(input: Int64, output: Int64, coverage: TokenBreakdown) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10 * scale, verticalSpacing: 0) {
            GridRow {
                modelMetric("Input", NotchPresentation.compact(input) + (coverage.isIncomplete ? "*" : ""),
                            color: Palette.tokenInput)
                modelMetric("Output", NotchPresentation.compact(output), color: Palette.tokenOutput)
            }
            GridRow {
                modelMetric("Cache Read", coverage.read.displayValue(compact: true), color: Palette.tokenCacheRead)
                modelMetric("Cache Write", coverage.write.displayValue(compact: true), color: Palette.tokenCacheWrite)
            }
        }
        .font(type.cardSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var separator: some View {
        Text("\u{00B7}")
    }

    private func modelMetric(_ title: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
            Circle().fill(color)
                .frame(width: 5 * scale, height: 5 * scale)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1.5 * scale }
                .accessibilityHidden(true)
            Text(title).foregroundStyle(Palette.secondary)
            Text(value).monospacedDigit().foregroundStyle(Palette.primary)
        }
        .fixedSize()
    }

    // A two-word switch, not a segmented control: the stock one arrives with
    // its own material and corner radius and reads as a borrowed part on a
    // surface that is otherwise pure black.
    private func period(_ title: String, _ value: HistoryRange) -> some View {
        let selected = presentation.range == value
        return Button { selectRange(value) } label: {
            Text(title)
                .font(type.cardSecondary)
                .foregroundStyle(selected ? Palette.primary : Palette.secondary)
                .padding(.bottom, 3 * scale)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Palette.primary : Color.clear)
                        .frame(height: NotchLayout.hairline * scale)
                }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var rule: some View {
        Rectangle().fill(Palette.barTrack).frame(height: NotchLayout.hairline * scale)
            .accessibilityHidden(true)
    }
}

struct CopilotSummaryView: View {
    let presentation: NotchPresentation
    let placement: NotchCardPlacement
    let openClient: (Client) -> Void
    let openUsage: () -> Void
    let openSettings: () -> Void
    let openHistory: () -> Void
    var selectRange: (HistoryRange) -> Void = { _ in }
    var selectSource: (UsageSource?) -> Void = { _ in }
    var openModel: (String?) -> Void = { _ in }
    var openAttention: (String?) -> Void = { _ in }
    var openConnections: () -> Void = {}
    var openActivity: () -> Void = {}
    var toggleModels: () -> Void = {}
    var openSession: (SessionDetailTarget, String?) -> Void = { _, _ in }
    var dismissRequest: (String) -> Void = { _ in }
    var noticeVisibility: (String, Bool) -> Void = { _, _ in }
    var openPricing: () -> Void = {}

    private var scale: CGFloat { placement.scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            placement.shape.fill(Palette.surface)
            VStack(spacing: NotchLayout.blockSpacing * scale) {
                ScrollView {
                    CopilotSummaryContent(presentation: presentation, scale: scale, openClient: openClient,
                        openHistory: openHistory,
                        selectRange: selectRange,
                        selectSource: selectSource,
                        openModel: openModel, openDetails: openActivity, openAllowance: openUsage,
                        openAttention: openAttention,
                        openConnections: openConnections, toggleModels: toggleModels,
                        openSession: openSession, dismissRequest: dismissRequest,
                        noticeVisibility: noticeVisibility)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                Rectangle().fill(Palette.barTrack).frame(height: NotchLayout.hairline * scale)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack {
                        Button("View history", action: openHistory)
                        Spacer(minLength: 4 * scale)
                        Button("Settings\u{2026}", action: openSettings)
                            .keyboardShortcut(",", modifiers: .command)
                        Spacer(minLength: 4 * scale)
                        Button("GitHub model pricing \u{2197}", action: openPricing)
                            .font(Typography(scale: scale).cardCaption)
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                            .help(NotchLayout.modelPricingURL)
                            .accessibilityLabel("GitHub model pricing")
                            .accessibilityHint("Opens GitHub's Copilot model pricing page in your browser.")
                    }
                    .font(Typography(scale: scale).cardBody)
                    .buttonStyle(NotchCardButtonStyle(scale: scale))
                    .frame(height: NotchLayout.footerHeight * scale)
                    provenance
                }
            }
            .padding(NotchLayout.cardPadding * scale)
            .frame(width: placement.bodyRect.width, height: placement.bodyRect.height)
            .position(x: placement.bodyRect.midX, y: placement.bodyRect.midY)
        }
        .frame(width: placement.frame.width, height: placement.frame.height)
        .foregroundStyle(Palette.primary)
        .preferredColorScheme(.dark)
    }

    // Fine print, not a section: it qualifies every figure above, so it sits
    // beneath the whole card rather than inside Models Breakdown.
    @ViewBuilder private var provenance: some View {
        Group {
            if presentation.usageSource == .saved || presentation.usageSource == .live {
                Text(presentation.provenance)
                    .font(Typography(scale: scale).cardFinePrint)
                    .foregroundStyle(presentation.tokensPartial && presentation.usageSource == .live ? Palette.watch : Palette.secondary)
                    .lineLimit(1)
                    .help(presentation.sourceDetails)
                    .accessibilityLabel("\(presentation.provenance). \(presentation.sourceDetails)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: NotchLayout.provenanceHeight * scale, alignment: .bottom)
    }
}

/// Nothing in the card looked clickable until it was already being clicked.
/// Hover now lights the whole row, and `inset` lets a full-width row opt out of
/// the padding that a short inline action needs.
struct NotchCardButtonStyle: ButtonStyle {
    var inset = true
    var scale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, inset: inset, scale: scale)
    }

    private final class Hover: ObservableObject {
        @Published var isInside = false
    }

    private struct Surface: View {
        let configuration: Configuration
        let inset: Bool
        let scale: CGFloat
        @StateObject private var hover = Hover()

        private var fill: Color {
            if configuration.isPressed { return Palette.ringTrack }
            return hover.isInside ? Palette.hover : .clear
        }

        var body: some View {
            configuration.label
                .foregroundStyle(Palette.primary)
                .padding(.horizontal, inset ? 5 * scale : 0)
                .padding(.vertical, inset ? 2 * scale : 0)
                .background(fill, in: RoundedRectangle(cornerRadius: 5 * scale))
                .contentShape(Rectangle())
                .onHover { hover.isInside = $0 }
        }
    }
}
