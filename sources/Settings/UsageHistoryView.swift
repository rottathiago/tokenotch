import Charts
import TokenotchCore
import SwiftUI

private final class HistoryConfirmationState: ObservableObject {
    @Published var consent = false
    @Published var deletion = false
}

extension View {
    func historyConsentDialog(isPresented: Binding<Bool>, history: HistoryController, provider: UsageProvider = .copilot) -> some View {
        confirmationDialog("Save \(provider.title) usage history on this Mac?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Turn On History") { history.setEnabled(true, provider: provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tokenotch saves \(provider.title) daily token, model and reported estimated cost totals until you delete them, plus hourly detail for seven days. No prompts, code or project names. Other providers' recording choices are unchanged.")
        }
    }
}

/// Recording and deletion controls, shown in Privacy.
struct HistoryControls: View {
    @ObservedObject var history: HistoryController
    var showsManagement = true
    var provider: UsageProvider = .copilot
    @StateObject private var state = HistoryConfirmationState()

    var body: some View {
        Toggle(isOn: Binding(get: { history.isEnabled(provider) }, set: { value in
            if value { state.consent = true } else { history.setEnabled(false, provider: provider) }
        })) {
            Text("Save usage history")
            Text(history.error ?? (history.recordingProviders.contains(provider) ? "Recording observed usage" :
                history.isEnabled(provider) ? "Waiting for a connected source" : "Paused; saved data is retained"))
        }
        .historyConsentDialog(isPresented: $state.consent, history: history, provider: provider)
        if let error = history.error {
            LabeledContent {
                Button("Retry") { history.retry() }
            } label: {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution)
            }
        }
        if showsManagement {
            LabeledContent {
                Button("Delete…", role: .destructive) { state.deletion = true }
            } label: {
                Text("Delete usage history")
                Text("Removes \(provider.title) daily, hourly and estimated cost totals.")
            }
            .confirmationDialog("Delete \(provider.title) usage history?", isPresented: $state.deletion, titleVisibility: .visible) {
                Button("Delete Usage History", role: .destructive) { history.delete(provider: provider) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone. Includes saved estimated cost aggregates and this provider's replay receipts. Recording consent is unchanged. Other providers, saved session timelines and live data aren't affected.")
            }
        }
    }
}

private final class HistorySelection: ObservableObject {
    @Published var modelProvider: UsageProvider?
    @Published var providerSnapshots: [UsageProvider: HistorySnapshot] = [:]
    @Published var modelComparison: HistoryInsightComparison?
    @Published var range: HistoryRange = .days30
    @Published var selected = Date()
    @Published var comparison = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @Published var model: String?
    @Published var snapshot: HistorySnapshot?
    @Published var baseline: HistorySnapshot?
    @Published var comparisonCurrent: HistorySnapshot?
    @Published var queryError: String?
    @Published var loading = false
    @Published var anchor: Date?
    @Published var hoveredDay: Date?
    @Published var consent = false
}

private struct DailyTokenPoint: Identifiable {
    let date: Date
    let kind: String
    let value: Int64
    var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
}

private struct ComparisonMetric: Identifiable {
    let title: String
    let current: String
    let previous: String
    let change: String
    var id: String { title }
}

private struct DayRow: Identifiable {
    let key: String
    let date: Date?
    let day: HistoryDay?
    var id: String { key }
}

struct UsageHistoryView: View {
    @ObservedObject var history: HistoryController
    @StateObject private var state = HistorySelection()
    private var calendar: HistoryCalendar { HistoryCalendar(zone: TimeZone(identifier: history.zone) ?? .current) }
    private var interval: DateInterval { calendar.interval(state.range, selected: state.selected, now: state.anchor ?? Date()) }
    private var monthly: Bool { [.month, .previousMonth, .chosenMonth].contains(state.range) }
    private var multiDay: Bool { calendar.keys(interval).count > 1 }
    private var prior: DateInterval {
        if state.range == .day || state.range == .chosenMonth {
            return calendar.interval(state.range, selected: state.comparison, now: Date())
        }
        return calendar.prior(interval, monthly: monthly)
    }
    private var comparisonIntervals: (DateInterval, DateInterval) {
        calendar.completedComparison(interval, prior, now: Date(), monthly: monthly)
    }
    private var queryID: String {
        "\(history.revision)|\(history.zone)|\(state.range.rawValue)|\(state.selected)|\(state.comparison)|\(state.model ?? "<all>")|\(String(describing: state.anchor))|\(history.selectedProvider?.rawValue ?? "all")|\(history.selectedSource?.rawValue ?? "all")"
    }

    var body: some View {
        Form {
            if let error = history.error {
                Section {
                    LabeledContent {
                        Button("Retry") { history.retry() }
                    } label: {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution)
                    }
                }
            }
            filters
            if let queryError = state.queryError {
                Section { Label(queryError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution) }
            } else if let snapshot = state.snapshot {
                if !history.selectionEnabled { pausedNotice }
                summary(snapshot)
                if multiDay {
                    if history.selectedProvider == nil && history.selectedSource == nil {
                        ForEach(UsageProvider.allCases) { provider in
                            if let scoped = state.providerSnapshots[provider] {
                                dailyChart(scoped, provider: provider)
                            }
                        }
                    } else { dailyChart(snapshot) }
                }
                models(snapshot)
                if let current = state.comparisonCurrent, let baseline = state.baseline {
                    comparison(current, baseline)
                }
                insights
                context(snapshot)
                if multiDay { dailyTable(snapshot) }
            } else if state.loading {
                Section { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20) }
            } else if history.error == nil {
                Section { emptyState }
            }
            if history.selectedProvider != .claudeCode && history.selectedSource?.provider != .claudeCode {
                TelemetryImportView(history: history)
            }
            if let snapshot = state.snapshot, state.queryError == nil {
                Section {} footer: {
                    SettingsFootnote("Times use \(snapshot.zone). \(snapshot.comparisonBegan.map { "Comparable recording since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Recording baseline unavailable"), \(ByteCountFormatter.string(fromByteCount: snapshot.bytes, countStyle: .file)) on disk. Estimates from this Mac, not billing data.")
                }
            }
        }
        .formStyle(.grouped)
        .environment(\.timeZone, calendar.calendar.timeZone)
        .historyConsentDialog(isPresented: $state.consent, history: history, provider: history.selectedSource?.provider ?? history.selectedProvider ?? .copilot)
        .task(id: queryID) { await load() }
        .onChange(of: history.selectedProvider) {
            if state.modelProvider != history.selectedProvider { state.model = nil; state.modelProvider = nil }
            clearSnapshots()
        }
        .onChange(of: history.selectedSource) { clearSnapshots() }
        .onChange(of: history.navigation?.id, initial: true) {
            guard let request = history.navigation else { return }
            state.anchor = request.anchor
            state.range = request.range
            state.model = request.model
            state.selected = request.anchor
            history.navigation = nil
        }
        .sheet(item: $history.selectedEvidence) { evidence in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Weekly insight").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { history.selectedEvidence = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(20)
                Divider()
                ScrollView {
                    HistoryInsightEvidenceView(evidence: evidence)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            .frame(width: 620, height: 620)
        }
    }

    // MARK: Filters

    private var filters: some View {
        Section {
            HStack(spacing: 10) {
                Picker("Period", selection: Binding(get: { state.range }, set: {
                    state.anchor = nil
                    state.range = $0
                })) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                UsageProviderPicker(history: history).fixedSize()
                UsageSourcePicker(selection: $history.selectedSource, provider: history.selectedProvider).fixedSize()
                Menu {
                    Button("All models") { state.model = nil; state.modelProvider = nil }
                    Divider()
                    ForEach(modelOptions) { item in
                        Button("\(item.provider.title): \(item.title)") {
                            state.modelProvider = item.provider
                            history.selectedProvider = item.provider
                            state.model = item.model
                        }
                    }
                } label: {
                    Text(state.model.map { HistoryModel(id: $0, tokens: HistoryTotals()).title } ?? "All models")
                        .lineLimit(1).truncationMode(.middle)
                }
                .fixedSize()
                .frame(maxWidth: 200, alignment: .leading)
                Spacer(minLength: 4)
                if state.loading && state.snapshot != nil { ProgressView().controlSize(.small) }
                recordingBadge
            }
            .labelsHidden()
            if state.range == .day || state.range == .chosenMonth {
                DatePicker(state.range == .day ? "Day" : "Month", selection: $state.selected,
                           in: ...Date(), displayedComponents: .date)
                DatePicker("Compare with", selection: $state.comparison, in: ...Date(), displayedComponents: .date)
            }
        }
    }

    private var recordingBadge: some View {
        Group {
            if history.error != nil {
                StatusBadge(text: "Unavailable", symbol: "exclamationmark.triangle.fill", tone: .caution)
            } else if !history.selectionEnabled {
                StatusBadge(text: "Off", tone: .neutral)
            } else if history.selectionRecording {
                StatusBadge(text: "Recording", symbol: "record.circle", tone: .good)
            } else {
                StatusBadge(text: "Waiting for a client", tone: .neutral)
            }
        }
        .help(history.status)
    }

    private var pausedNotice: some View {
        Section {
            LabeledContent {
                Button("Turn On…") { state.consent = true }
            } label: {
                Text("History is off")
                Text("Saved usage is shown below. New usage isn't being saved.")
            }
        }
    }

    private var emptyState: some View {
        Group {
            if history.enabled {
                EmptyStateView(symbol: "chart.bar.xaxis", title: "No history yet",
                               message: "Usage from connected clients appears here after your next Copilot request.")
            } else {
                EmptyStateView(symbol: "chart.bar.xaxis", title: "Track usage over time",
                               message: "Save daily token and model totals on this Mac to see trends, compare periods and spot changes.") {
                    Button("Turn On History…") { state.consent = true }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Summary

    private func summary(_ snapshot: HistorySnapshot) -> some View {
        let totals = snapshot.totals
        let days = max(calendar.dayCount(DateInterval(start: interval.start, end: min(interval.end, calendar.addingDays(1, to: calendar.calendar.startOfDay(for: Date()))))), 1)
        let activeDays = snapshot.days.filter { $0.tokens.calls > 0 }.count
        return Section {
            if totals.calls == 0 {
                Text("No usage was recorded in this period.").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                StatRow(tiles: [
                    StatTile(title: "Tokens", value: MetricFormat.tokens(totals.total), help: totals.breakdown.totalDetails),
                    StatTile(title: "Model calls", value: MetricFormat.tokens(totals.calls)),
                    StatTile(title: multiDay ? "Daily average" : "Per call",
                             value: multiDay ? MetricFormat.tokens(totals.total / Int64(days))
                                : MetricFormat.tokens(totals.total / max(totals.calls, 1)),
                             detail: multiDay ? "\(activeDays) of \(days) days active" : nil),
                    StatTile(title: "Response time", value: MetricFormat.latency(totals.meanDuration),
                             detail: totals.meanFirstToken.map { "First token \(MetricFormat.latency($0))" })
                ])
                TokenMixBar(segments: TokenMixSegment.segments(input: totals.input, output: totals.output, breakdown: totals.breakdown,
                                                cacheRead: totals.cacheInput, cacheWrite: totals.cacheWrite),
                            help: totals.breakdown.details)
                    .padding(.vertical, 2)
                if (history.selectedSource?.provider ?? history.selectedProvider) == .claudeCode {
                    EstimatedCostRow(coverage: totals.costCoverage)
                } else if history.selectedProvider == nil, let claude = state.providerSnapshots[.claudeCode] {
                    EstimatedCostRow(coverage: claude.totals.costCoverage)
                }
            }
        } header: {
            Text(periodTitle)
        } footer: {
            if snapshot.hasImportedData {
                SettingsFootnote("Includes imported usage.")
            }
        }
    }

    private var periodTitle: String {
        let last = calendar.addingDays(-1, to: interval.end)
        if !multiDay { return interval.start.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
        return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    // MARK: Daily chart

    private func points(_ snapshot: HistorySnapshot) -> [DailyTokenPoint] {
        snapshot.days.filter { $0.tokens.calls > 0 }.flatMap { day -> [DailyTokenPoint] in
            guard let date = calendar.date(day.day) else { return [] }
            var values = [DailyTokenPoint(date: date, kind: "Input", value: day.tokens.input),
                          DailyTokenPoint(date: date, kind: "Output", value: day.tokens.output)]
            if day.tokens.cacheCoverage.hasValue {
                values.append(DailyTokenPoint(date: date, kind: "Cache read", value: day.tokens.cacheInput))
            }
            if day.tokens.breakdown.write.hasValue {
                values.append(DailyTokenPoint(date: date, kind: "Cache write", value: day.tokens.cacheWrite))
            }
            return values
        }
    }

    private func dailyChart(_ snapshot: HistorySnapshot, provider: UsageProvider? = nil) -> some View {
        let data = points(snapshot)
        let hovered = state.hoveredDay.flatMap { date in snapshot.days.first { $0.day == calendar.key(date) } }
        let peak = snapshot.days.map { day in
            day.tokens.input + day.tokens.output
                + (day.tokens.cacheCoverage.hasValue ? day.tokens.cacheInput : 0)
                + (day.tokens.breakdown.write.hasValue ? day.tokens.cacheWrite : 0)
        }.max() ?? 0
        return Section {
            if let provider { Text(provider.title).font(.headline) }
            if data.isEmpty {
                Text("Nothing to chart for this period.").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                Chart {
                    ForEach(data) { point in
                        BarMark(x: .value("Day", point.date, unit: .day), y: .value("Tokens", point.value))
                            .foregroundStyle(by: .value("Kind", point.kind))
                            .cornerRadius(1.5)
                    }
                    if let date = state.hoveredDay, let hovered, hovered.tokens.calls > 0 {
                        RuleMark(x: .value("Day", date, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Day", date, unit: .day), y: .value("Tokens", hovered.tokens.total))
                            .opacity(0)
                            .annotation(position: .top, spacing: 6,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                tooltip(date: date, day: hovered)
                            }
                    }
                }
                .chartForegroundStyleScale([
                    "Input": Palette.tokenInput, "Output": Palette.tokenOutput,
                    "Cache read": Palette.tokenCacheRead, "Cache write": Palette.tokenCacheWrite
                ])
                .chartXScale(domain: interval.start...interval.end)
                .chartYScale(domain: 0...max(peak * 6 / 5, 1))
                .chartXSelection(value: $state.hoveredDay)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel {
                            if let tokens = value.as(Int64.self) { Text(MetricFormat.tokens(tokens)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .frame(height: 230)
                .padding(.vertical, 6)
                .accessibilityLabel("Daily tokens. The daily breakdown table lists each day.")
            }
        } header: {
            Text("Daily tokens")
        } footer: {
            SettingsFootnote("Days without a bar had no recorded usage. Hover a day for details.")
        }
    }

    private func tooltip(date: Date, day: HistoryDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.caption.weight(.semibold))
            Text("\(day.tokens.total.formatted()) tokens").monospacedDigit()
            Text("\(day.tokens.calls.formatted()) calls").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }

    // MARK: Models

    private func models(_ snapshot: HistorySnapshot) -> some View {
        let rows = snapshot.models.filter { (state.model == nil || $0.model == state.model) && $0.tokens.calls > 0 }
            .sorted { $0.tokens.total > $1.tokens.total }
        let total = max(snapshot.totals.total, 1)
        return Group {
            if !rows.isEmpty {
                Section {
                    MetricTable(columns: [
                        TableColumnSpec(title: "Model", alignment: .leading),
                        TableColumnSpec(title: "Share", alignment: .leading),
                        TableColumnSpec(title: "Tokens"),
                        TableColumnSpec(title: "Calls"),
                        TableColumnSpec(title: "First token", help: "Mean time to first token"),
                        TableColumnSpec(title: "Duration", help: "Mean call duration")
                    ], rows: rows) { item, column in
                        switch column {
                        case 0:
                            Button {
                                let clear = state.model == item.model && history.selectedProvider == item.provider
                                state.modelProvider = item.provider
                                history.selectedProvider = item.provider
                                state.model = clear ? nil : item.model
                            } label: {
                                Text(history.selectedProvider == nil ? "\(item.provider.title): \(item.title)" : item.title)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(state.model == item.model ? "Show all models" : "Show only \(item.title)")
                        case 1:
                            let share = Double(item.tokens.total) / Double(total)
                            HStack(spacing: 6) {
                                MeterBar(fraction: share, color: Palette.tokenInput, height: 5).frame(width: 56)
                                Text(MetricFormat.percent(share)).foregroundStyle(.secondary)
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                        case 2: Text(MetricFormat.tokens(item.tokens.total)).help(item.tokens.breakdown.details)
                        case 3: Text(MetricFormat.tokens(item.tokens.calls)).foregroundStyle(.secondary)
                        case 4: Text(MetricFormat.latency(item.tokens.meanFirstToken)).foregroundStyle(.secondary)
                        default: Text(MetricFormat.latency(item.tokens.meanDuration)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    SettingsFootnote(state.model == nil ? "Select a model to filter this page." : "Select the model again to show all models.")
                }
            }
        }
    }

    // MARK: Comparison

    private func comparison(_ current: HistorySnapshot, _ baseline: HistorySnapshot) -> some View {
        let ranges = comparisonIntervals
        let a = current.totals, b = baseline.totals
        let today = calendar.calendar.startOfDay(for: Date())
        let incomplete = ranges.0.end > today || ranges.1.end > today
        let comparable = a.unverifiedCalls == 0 && b.unverifiedCalls == 0 && !incomplete && a.calls > 0 && b.calls > 0
        func change(_ left: Double?, _ right: Double?) -> String {
            guard comparable, let left, let right else { return "—" }
            return MetricFormat.change(HistoryCalendar.percentage(current: left, baseline: right))
        }
        let currentDays = max(calendar.dayCount(ranges.0), 1), previousDays = max(calendar.dayCount(ranges.1), 1)
        let metrics = [
            ComparisonMetric(title: "Tokens", current: MetricFormat.tokens(a.total), previous: MetricFormat.tokens(b.total),
                             change: change(Double(a.total), Double(b.total))),
            ComparisonMetric(title: "Tokens per day", current: MetricFormat.tokens(a.total / Int64(currentDays)),
                             previous: MetricFormat.tokens(b.total / Int64(previousDays)),
                             change: change(Double(a.total) / Double(currentDays), Double(b.total) / Double(previousDays))),
            ComparisonMetric(title: "Model calls", current: a.calls.formatted(), previous: b.calls.formatted(),
                             change: change(Double(a.calls), Double(b.calls))),
            ComparisonMetric(title: "First token", current: MetricFormat.latency(a.meanFirstToken),
                             previous: MetricFormat.latency(b.meanFirstToken), change: change(a.meanFirstToken, b.meanFirstToken)),
            ComparisonMetric(title: "Call duration", current: MetricFormat.latency(a.meanDuration),
                             previous: MetricFormat.latency(b.meanDuration), change: change(a.meanDuration, b.meanDuration))
        ]
        return Section {
            if a.calls == 0 || b.calls == 0 {
                Text("Both periods need recorded usage to compare.").foregroundStyle(.secondary)
            } else {
                MetricTable(columns: [
                    TableColumnSpec(title: "", alignment: .leading),
                    TableColumnSpec(title: shortPeriod(ranges.0)),
                    TableColumnSpec(title: shortPeriod(ranges.1)),
                    TableColumnSpec(title: "Change")
                ], rows: metrics) { metric, column in
                    switch column {
                    case 0: Text(metric.title).frame(maxWidth: .infinity, alignment: .leading)
                    case 1: Text(metric.current)
                    case 2: Text(metric.previous).foregroundStyle(.secondary)
                    default: Text(metric.change).fontWeight(.medium)
                    }
                }
            }
        } header: {
            Text("Compared with previous period")
        } footer: {
            SettingsFootnote(incomplete ? "The current period isn't finished, so changes aren't shown yet."
                             : "Compares completed days only. Missing days aren't counted as zero.")
        }
    }

    private func shortPeriod(_ period: DateInterval) -> String {
        guard calendar.dayCount(period) > 0 else { return "—" }
        let last = calendar.addingDays(-1, to: period.end)
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return calendar.dayCount(period) == 1 ? period.start.formatted(format)
            : "\(period.start.formatted(format))–\(last.formatted(format))"
    }

    // MARK: Insights

    @ViewBuilder private var insights: some View {
        if let comparison = state.model == nil ? history.comparison : state.modelComparison,
           !comparison.insights.isEmpty {
            Section {
                ForEach(comparison.insights.filter {
                    ($0.kind != .compaction || (history.selectedProvider == .copilot && state.model == nil)) &&
                        ($0.kind != .modelMix || state.model == nil)
                }) { insight in
                    Button {
                        history.selectedEvidence = comparison.evidence(for: insight)
                    } label: {
                        HStack {
                            Image(systemName: insight.eligible ? "chart.line.uptrend.xyaxis" : "chart.line.flattrend.xyaxis")
                                .foregroundStyle(insight.eligible ? SettingsStyle.brand : Color.secondary)
                                .frame(width: 20)
                            Text(insight.headline).foregroundStyle(insight.eligible ? .primary : .secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Weekly insights")
            } footer: {
                if comparison.insights.allSatisfy({ !$0.eligible }) {
                    SettingsFootnote("Insights need two complete weeks of history.")
                }
            }
        }
    }

    // MARK: Context

    @ViewBuilder private func context(_ snapshot: HistorySnapshot) -> some View {
        let peak = snapshot.days.compactMap(\.contextMaximum).max()
        let compacted = snapshot.days.contains(where: \.hasCompaction)
        if peak != nil || compacted {
            Section {
                if let peak {
                    LabeledContent("Peak context") {
                        HStack(spacing: 8) {
                            MeterBar(fraction: peak, color: SettingsStyle.usage(peak), height: 5).frame(width: 90)
                            Text(MetricFormat.percent(peak)).monospacedDigit()
                        }
                    }
                }
                if compacted {
                    LabeledContent("Compactions",
                                   value: snapshot.days.reduce(Int64(0)) { $0 + $1.compactions }.formatted())
                    let failed = snapshot.days.reduce(Int64(0)) { $0 + $1.failedCompactions }
                    if failed > 0 { LabeledContent("Failed compactions", value: failed.formatted()) }
                }
            } header: {
                Text("Context window")
            } footer: {
                SettingsFootnote("Covers all models. Copilot CLI only.")
            }
        }
    }

    // MARK: Daily table

    private func dailyTable(_ snapshot: HistorySnapshot) -> some View {
        let todayKey = calendar.key(Date())
        let rows = calendar.keys(interval).reversed().filter { $0 <= todayKey }.map { key in
            DayRow(key: key, date: calendar.date(key), day: snapshot.days.first { $0.day == key })
        }
        return Section {
            DisclosureGroup("Daily breakdown") {
                MetricTable(columns: [
                    TableColumnSpec(title: "Day", alignment: .leading),
                    TableColumnSpec(title: "Tokens"),
                    TableColumnSpec(title: "Calls"),
                    TableColumnSpec(title: "Recorded", help: "How long Tokenotch was able to record that day")
                ], rows: rows) { row, column in
                    switch column {
                    case 0:
                        HStack(spacing: 4) {
                            Text(row.date?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? row.key)
                            if row.key == todayKey { Text("Today").foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case 1:
                        Text(row.day.map { $0.tokens.calls > 0 ? $0.tokens.total.formatted() : "—" } ?? "—")
                    case 2:
                        Text(row.day.map { $0.tokens.calls > 0 ? $0.tokens.calls.formatted() : "—" } ?? "—")
                            .foregroundStyle(.secondary)
                    default:
                        HStack(spacing: 4) {
                            if row.day?.gap == true {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution)
                                    .help("Recording was interrupted. Some usage may be missing.")
                            }
                            Text(row.day.map { duration($0.recordingSeconds) } ?? "Not recorded")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private var modelOptions: [HistoryModel] {
        var values: [String: HistoryModel] = [:]
        for item in (state.snapshot?.models ?? []) + (state.baseline?.models ?? []) { values[item.id] = item }
        if let model = state.model, !values.values.contains(where: {
            $0.model == model && (state.modelProvider == nil || $0.provider == state.modelProvider)
        }) {
            let fallback = HistoryModel(id: model, tokens: HistoryTotals(),
                provider: state.modelProvider ?? history.selectedProvider ?? .copilot)
            values[fallback.id] = fallback
        }
        return values.values.sorted { $0.title < $1.title }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        state.loading = true
        state.queryError = nil
        clearSnapshots()
        let selectedInterval = interval, pair = comparisonIntervals, selectedModel = state.model
        let scope = HistoryQueryScope(provider: history.selectedProvider, source: history.selectedSource)
        do {
            let full = try await history.read(selectedInterval, model: selectedModel, scope: scope)
            let left = try await history.read(pair.0, model: selectedModel, scope: scope)
            let right = try await history.read(pair.1, model: selectedModel, scope: scope)
            var providers: [UsageProvider: HistorySnapshot] = [:]
            if scope.provider == nil && scope.source == nil {
                for provider in UsageProvider.allCases {
                    providers[provider] = try await history.read(selectedInterval, model: selectedModel,
                        scope: HistoryQueryScope(provider: provider, source: nil))
                }
            }
            var modelComparison: HistoryInsightComparison?
            if let selectedModel {
                let periods = HistoryInsightComparison.periods(now: Date(), calendar: calendar)
                let current = try await history.read(periods.0, model: selectedModel, scope: scope)
                let previous = try await history.read(periods.1, model: selectedModel, scope: scope)
                func filtered(_ snapshot: HistorySnapshot) -> HistorySnapshot {
                    HistorySnapshot(days: snapshot.days, models: snapshot.models.filter { $0.model == selectedModel },
                        zone: snapshot.zone, began: snapshot.began, bytes: snapshot.bytes, totals: snapshot.totals,
                        hasImportedData: snapshot.hasImportedData, recordingCoverage: snapshot.recordingCoverage)
                }
                if let current, let previous {
                    modelComparison = try HistoryInsightComparison(current: filtered(current), previous: filtered(previous), now: Date())
                }
            }
            try Task.checkCancellation()
            state.snapshot = full; state.comparisonCurrent = left; state.baseline = right
            state.providerSnapshots = providers
            state.modelComparison = modelComparison
            state.loading = false
        } catch is CancellationError {
            // The next selection owns the loading state.
        } catch {
            guard !Task.isCancelled else { return }
            state.queryError = (error as? HistoryError)?.rawValue ?? HistoryError.storage.rawValue
            state.snapshot = nil; state.baseline = nil; state.comparisonCurrent = nil
            state.loading = false
        }
    }

    private func clearSnapshots() {
        state.snapshot = nil; state.baseline = nil; state.comparisonCurrent = nil
        state.providerSnapshots = [:]
        state.modelComparison = nil
    }
}
