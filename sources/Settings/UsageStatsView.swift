import TokenotchCore
import SwiftUI

extension CacheInputCoverage {
    func displayValue(compact: Bool = false) -> String {
        switch state {
        case .noSamples: return compact ? "-" : "No samples"
        case .notReported: return compact ? "n/r" : "Not reported"
        case .unknown: return compact ? "?" : "Unknown"
        case .reported, .partial:
            let number = compact ? NotchPresentation.compact(tokens) : tokens.formatted()
            return number + (state == .partial ? "*" : "")
        }
    }

    var details: String {
        let reading: String
        let label = kind == .read ? "Cache read" : "Cache write"
        switch state {
        case .noSamples: return "No \(label.lowercased()) samples observed."
        case .reported: reading = "\(tokens.formatted()) \(label.lowercased()) tokens."
        case .notReported: reading = "\(label) not reported by the runtime."
        case .unknown: reading = "\(label) unknown; older observations did not preserve reporting availability."
        case .partial: reading = "\(tokens.formatted()) known \(label.lowercased()) tokens; partial, not a complete category total."
        }
        return "\(reading) \(reportedCalls.formatted()) of \(calls.formatted()) calls reported cache counts; " +
            "\(unreportedCalls.formatted()) did not report them; \(unknownCalls.formatted()) have unknown legacy coverage."
    }
}

extension TokenBreakdown {
    static let usageNotice = "Estimated local usage. For official usage and billing, check GitHub or your enterprise dashboard."
    var inlineDetails: String {
        unverifiedCalls > 0 ? "\(read.details) \(write.details)" : details
    }
    var details: String { "\(read.details) \(write.details) \(totalDetails)" }
    var totalDetails: String {
        if unverifiedCalls > 0 {
            return "\(unverifiedCalls.formatted()) legacy calls retain their original counts; input and cache may overlap. Not a verified unique-token total or cost estimate."
        }
        return "Observed total: runtime inclusive input + output, with cache tokens counted once. Not cost weighted." +
            (isIncomplete ? " Input breakdown incomplete: remaining input includes any unreported cache activity." : "")
    }
}

struct TokenMixSegment: Identifiable {
    let title: String
    let value: Int64
    let display: String
    let color: Color
    var id: String { title }
}

extension TokenMixSegment {
    static func segments(input: Int64, output: Int64, breakdown: TokenBreakdown,
                         cacheRead: Int64, cacheWrite: Int64) -> [TokenMixSegment] {
        [
            TokenMixSegment(title: "Input", value: input, display: MetricFormat.tokens(input), color: Palette.tokenInput),
            TokenMixSegment(title: "Output", value: output, display: MetricFormat.tokens(output), color: Palette.tokenOutput),
            TokenMixSegment(title: "Cache read", value: breakdown.read.hasValue ? cacheRead : 0,
                            display: breakdown.read.displayValue(compact: true), color: Palette.tokenCacheRead),
            TokenMixSegment(title: "Cache write", value: breakdown.write.hasValue ? cacheWrite : 0,
                            display: breakdown.write.displayValue(compact: true), color: Palette.tokenCacheWrite)
        ]
    }
}

/// One horizontal bar that shows how a token total splits across categories.
struct TokenMixBar: View {
    let segments: [TokenMixSegment]
    var help: String?

    private var total: Int64 { segments.reduce(0) { $0 + max($1.value, 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let visible = segments.filter { $0.value > 0 }
                let spacing: CGFloat = 2
                let width = max(proxy.size.width - spacing * CGFloat(max(visible.count - 1, 0)), 0)
                HStack(spacing: spacing) {
                    if visible.isEmpty { Capsule().fill(.quaternary) }
                    ForEach(visible) { segment in
                        Rectangle().fill(segment.color)
                            .frame(width: max(3, width * CGFloat(Double(segment.value) / Double(max(total, 1)))))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 7, height: 7)
                        Text(segment.title).foregroundStyle(.secondary)
                        Text(segment.display).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        .help(help ?? "")
    }
}

struct UsageTabView: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var history: HistoryController

    init(model: TokenotchModel) {
        self.model = model
        history = model.history
    }

    var todayUsage: NotchPresentation { NotchPresentation(model: model, range: .today) }

    var body: some View {
        let usage = todayUsage
        Form {
            if let message = model.notificationNavigationMessage {
                Section {
                    LabeledContent {
                        Button("Dismiss") { model.notificationNavigationMessage = nil }
                    } label: {
                        Label(message, systemImage: "bell.badge")
                    }
                }
            }
            if let target = model.selectedSession {
                SelectedSessionSection(model: model, target: model.currentTarget(target))
            }
            if let detail = model.liveUsageDetail {
                LiveSnapshotSection(model: model, detail: detail)
            }
            AccountQuotaSection(model: model)
            TodayUsageSection(model: model, presentation: usage)
            AttentionSection(model: model, attention: model.attention)
            LiveSessionsSection(model: model)
            if !usage.allModelRows.isEmpty {
                Section {
                    ModelUsageTable(models: Array(usage.allModelRows.prefix(12)))
                } header: {
                    Text("Models today")
                } footer: {
                    if usage.allModelRows.count > 12 {
                        SettingsFootnote("Showing the top 12 of \(usage.allModelRows.count) models. See History for the rest.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(model.usageNavigation)
    }
}

struct AccountQuotaSection: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        Section {
            AccountConnectionControls(model: model)
            if let snapshot = model.accountSnapshot {
                if snapshot.quotas.isEmpty {
                    Text("This account doesn't report a request quota.").foregroundStyle(.secondary)
                }
                ForEach(orderedQuotas(snapshot)) { quota in
                    QuotaMeterRow(quota: quota, prominent: quota.id == snapshot.primaryQuota?.id,
                                  observedAt: snapshot.observedAt)
                }
                .opacity(model.accountStale ? 0.6 : 1)
            }
        } header: {
            Text("Copilot plan")
        } footer: {
            if let snapshot = model.accountSnapshot {
                HStack {
                    SettingsFootnote("Reported by GitHub \(snapshot.observedAt.formatted(.relative(presentation: .named))). Refreshes every minute.")
                    Spacer()
                    Button("View on GitHub") { model.openUsage() }.buttonStyle(.link).font(.footnote)
                }
            } else {
                SettingsFootnote("Sign-in uses the official Copilot CLI. Tokenotch never sees your token.")
            }
        }
    }

    private func orderedQuotas(_ snapshot: CopilotAccountSnapshot) -> [CopilotQuota] {
        let primary = snapshot.primaryQuota?.id
        return snapshot.quotas.sorted { left, right in
            if (left.id == primary) != (right.id == primary) { return left.id == primary }
            return left.title < right.title
        }
    }
}

struct AccountConnectionControls: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        Group {
            if let snapshot = model.accountSnapshot {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.identity.login.map { "@\($0)" } ?? "GitHub account")
                            .font(.headline).textSelection(.enabled)
                        Text(MetricFormat.plan(snapshot.identity.copilotPlan) ?? "GitHub Copilot")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.accountStale {
                        StatusBadge(text: "Out of date", symbol: "clock.badge.exclamationmark", tone: .caution)
                            .help("The last refresh failed. Showing the most recent reading.")
                    }
                    if model.accountBusy { ProgressView().controlSize(.small) }
                    accountMenu
                }
                if model.accountStale { Text(model.accountStatus).font(.caption).foregroundStyle(SettingsStyle.caution) }
            } else if model.accountBusy {
                LabeledContent {
                    Button("Cancel") { model.disconnectAccount() }
                } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.accountStatus)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect your GitHub account")
                        Text("See your Copilot request quota and when it resets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign In…") { model.signInAccount() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.managedAccountDisabled || model.cliExecutable.isEmpty)
                }
                .padding(.vertical, 4)
                if model.cliExecutable.isEmpty {
                    LabeledContent {
                        Button("Choose…") { model.chooseCLI() }
                    } label: {
                        Label("Copilot CLI not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SettingsStyle.caution)
                    }
                } else if model.accountStatus != "Not connected" {
                    Text(model.accountStatus).font(.caption).foregroundStyle(.secondary)
                }
                if model.managedAccountDisabled {
                    Label("Account connection is turned off by your organization.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            Button("Refresh Now") { model.refreshAccount() }
                .disabled(model.accountBusy || !model.accountConnectionEnabled)
            Button("View Usage on GitHub") { model.openUsage() }
            Divider()
            Button(model.accountStale ? "Sign In Again…" : "Switch Account…") { model.signInAccount() }
                .disabled(model.accountBusy || model.managedAccountDisabled)
            Button("Choose Copilot CLI…") { model.chooseCLI() }
            Divider()
            Button("Disconnect", role: .destructive) { model.disconnectAccount() }
        } label: {
            Image(systemName: "ellipsis.circle").imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Account options")
    }
}

struct QuotaMeterRow: View {
    let quota: CopilotQuota
    let prominent: Bool
    let observedAt: Date

    private var used: Double { min(max(1 - quota.remainingPercentage / 100, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 8 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.title).fontWeight(prominent ? .medium : .regular)
                Spacer()
                if quota.isUnlimitedEntitlement {
                    StatusBadge(text: "Unlimited", tone: .good)
                } else {
                    Text("\(number(quota.usedRequests)) of \(number(quota.entitlementRequests))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !quota.isUnlimitedEntitlement {
                if prominent {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(MetricFormat.percent(used))
                            .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        Text("used").foregroundStyle(.secondary)
                    }
                }
                MeterBar(fraction: used, color: SettingsStyle.usage(used), height: prominent ? 10 : 6)
                HStack {
                    Text("\(quota.remainingPercentage.formatted(.number.precision(.fractionLength(0...1))))% remaining")
                    Spacer()
                    if let date = quota.reportedReset, date > observedAt {
                        Text("Resets \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let overage = quota.overage, overage > 0 {
                    Label("\(number(overage)) additional requests", systemImage: "plus.circle")
                        .font(.caption).foregroundStyle(SettingsStyle.caution)
                }
            }
        }
        .padding(.vertical, prominent ? 6 : 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quota.isUnlimitedEntitlement ? "\(quota.title), unlimited"
                            : "\(quota.title), \(Int((used * 100).rounded())) percent used")
    }

    private func number(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct TodayUsageSection: View {
    @ObservedObject var model: TokenotchModel
    let presentation: NotchPresentation

    var body: some View {
        Section {
            if presentation.usageSource == .unavailable {
                LabeledContent {
                    Button("Retry") { model.history.retry() }
                } label: {
                    Label(presentation.historyError ?? HistoryError.storage.rawValue,
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SettingsStyle.caution)
                }
            } else if presentation.usageSource == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading saved usage...").foregroundStyle(.secondary)
                }
            } else if let totals = presentation.usageTotals, totals.calls > 0 {
                StatRow(tiles: [
                    StatTile(title: "Tokens", value: MetricFormat.tokens(totals.total), help: totals.breakdown.totalDetails),
                    StatTile(title: "Model calls", value: totals.calls.formatted()),
                    presentation.usageSource == .saved
                        ? StatTile(title: "Per call", value: MetricFormat.tokens(totals.total / totals.calls))
                        : StatTile(title: "Sessions", value: model.sessions.filter { Calendar.current.isDateInToday($0.observedAt) }.count.formatted()),
                    presentation.usageSource == .saved
                        ? StatTile(title: "Response time", value: MetricFormat.latency(totals.meanDuration),
                                   detail: totals.meanFirstToken.map { "First token \(MetricFormat.latency($0))" })
                        : StatTile(title: "Last activity",
                                   value: presentation.tokens?.lastObserved.formatted(date: .omitted, time: .shortened) ?? "—")
                ])
                TokenMixBar(segments: TokenMixSegment.segments(input: totals.input, output: totals.output, breakdown: totals.breakdown,
                                                cacheRead: totals.cacheInput, cacheWrite: totals.cacheWrite),
                            help: totals.breakdown.details)
                    .padding(.vertical, 2)
                if presentation.usageSource == .live && presentation.tokensPartial {
                    Label("Sample limit reached. Today's totals are partial.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(SettingsStyle.caution)
                }
            } else {
                EmptyStateView(symbol: "chart.bar",
                               title: presentation.usageSource == .saved ? "No saved usage today" : "No usage yet today",
                               message: presentation.usageSource == .saved
                                   ? "No usage was recorded for this source in today's reporting period."
                                   : model.registeredClients.isEmpty
                                   ? "Connect Copilot CLI or VS Code to see token usage here."
                                   : "Usage appears after your next Copilot request.") {
                    if model.registeredClients.isEmpty {
                        Button("Open Connections") { model.settingsTab = .connections }
                    }
                }
            }
        } header: {
            HStack {
                Text("Today")
                Spacer()
                UsageSourcePicker(selection: Binding(get: { model.history.selectedSource },
                                                     set: { model.history.selectedSource = $0 }), compact: true)
            }
        } footer: {
            if presentation.usageSource == .saved || presentation.usageSource == .live {
                SettingsFootnote("\(presentation.provenance). \(presentation.savedUsage?.zone ?? TimeZone.current.identifier). \(TokenBreakdown.usageNotice)")
                    .help(presentation.sourceDetails)
            }
        }
    }
}

struct AttentionSection: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject var attention: SessionAttentionController

    var body: some View {
        if attention.error != nil || attention.state.notices.contains(where: { $0.disposition == .pending }) {
            Section("Needs attention") {
                SessionNoticeList(model: model, attention: attention, pendingOnly: true)
            }
        }
    }
}

private struct LiveSessionRow: Identifiable {
    let source: Client
    let key: String
    let session: ObservedSession?
    let metrics: ObservedSessionMetrics?
    var id: String { "\(source.rawValue):\(key)" }
    var last: Date { max(session?.observedAt ?? .distantPast, metrics?.lastObserved ?? .distantPast) }

    func signal(now: Date) -> SessionSignal {
        guard let session else { return .idle }
        if session.hasMissingActivity(now: now) { return .unknown }
        switch session.kind {
        case .working, .active: return session.isFresh(now: now) ? .working : .unknown
        case .stopped: return .stopped
        case .failed, .unrecoverableError: return .error
        case .inputRequested: return .input
        case .approvalRequested: return .approval
        default: return .idle
        }
    }

    func status(now: Date) -> String {
        if let session { return session.label(now: now) }
        return "Usage observed"
    }
}

struct LiveSessionsSection: View {
    @ObservedObject var model: TokenotchModel
    private let collapsedCount = 6

    private var rows: [LiveSessionRow] {
        var values: [String: LiveSessionRow] = [:]
        for session in model.sessions {
            values["\(session.source.rawValue):\(session.key)"] =
                LiveSessionRow(source: session.source, key: session.key, session: session, metrics: nil)
        }
        for metric in model.sessionMetrics where metric.sessionReported {
            let id = "\(metric.source.client.rawValue):\(metric.id)"
            let existing = values[id]
            values[id] = LiveSessionRow(source: metric.source.client, key: metric.id,
                                        session: existing?.session, metrics: metric)
        }
        return values.values.sorted { $0.last > $1.last }
    }

    var body: some View {
        let all = rows
        Section {
            if all.isEmpty {
                Text("No sessions in the last 24 hours.").foregroundStyle(.secondary)
            }
            ForEach(model.showLiveSessions ? all : Array(all.prefix(collapsedCount))) { row in
                sessionRow(row)
            }
            if all.count > collapsedCount {
                Button(model.showLiveSessions ? "Show Fewer" : "Show All \(all.count) Sessions") {
                    model.showLiveSessions.toggle()
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Sessions")
        } footer: {
            if !all.isEmpty {
                SettingsFootnote("Last 24 hours. Context is the latest reported window usage, not cumulative tokens. Dashed bars mean not reported. Session labels are shortened hashes, not project names.")
            }
        }
    }

    private func sessionRow(_ row: LiveSessionRow) -> some View {
        let signal = row.signal(now: model.clock)
        return HStack(spacing: 10) {
            Image(systemName: signal.symbol)
                .foregroundStyle(signal.settingsColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.source.shortTitle).fontWeight(.medium)
                    Text(row.key.prefix(8)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(row.status(now: model.clock))
                    Text(row.last.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SessionContextMeter(context: row.source == .cli ? model.insights.first { $0.id == row.key }?.context : nil,
                                source: row.source, now: model.clock)
                .frame(width: 130)
            if let tokens = row.metrics?.tokens {
                Text(MetricFormat.tokens(tokens.total))
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
                    .help("\(tokens.total.formatted()) tokens across \(tokens.calls.formatted()) calls")
            }
            Menu {
                Button("Session Details") {
                    model.selectedSession = SessionDetailTarget(source: row.source,
                        noticeSessionID: model.attention.state.sessionID(source: row.source, hash: row.key),
                        liveHash: row.key)
                    model.usageNavigation = UUID()
                }
                Button(row.source.openTitle) { model.openClient(row.source) }
                Button("View Timeline") { model.showTimeline(source: row.source, hash: row.key) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Session options")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

struct SelectedSessionSection: View {
    @ObservedObject var model: TokenotchModel
    let target: SessionDetailTarget

    var body: some View {
        Section {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: target.source.symbol, color: target.source == .cli ? .gray : .blue, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(target.source.shortTitle) session \(target.noticeSessionID.prefix(6))").font(.headline)
                    Text(model.sessions.first(where: { $0.source == target.source && $0.key == target.liveHash })?
                        .label(now: model.clock) ?? "Not currently observed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.selectedSession = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close session details")
            }
            SessionNoticeList(model: model, attention: model.attention, target: target)
            if target.source == .cli, let insight = model.insights.first(where: { $0.id == target.liveHash }) {
                SessionInsightView(insight: insight, now: model.clock)
            } else {
                SessionContextMeter(context: nil, source: target.source, now: model.clock)
            }
            HStack {
                Button(target.source.openTitle) { model.openClient(target.source) }
                if let hash = target.liveHash {
                    Button("View Timeline") { model.showTimeline(source: target.source, hash: hash) }
                }
                Spacer()
            }
        } header: {
            Text("Session details")
        } footer: {
            if target.liveHash == nil {
                SettingsFootnote("Live details appear when this session reports activity again.")
            }
        }
    }
}

struct LiveSnapshotSection: View {
    @ObservedObject var model: TokenotchModel
    let detail: LiveUsageDetail

    private var models: [ObservedModelTokens] {
        Array(detail.models.filter { detail.selectedModel == nil || $0.id == detail.selectedModel }.prefix(100))
    }

    var body: some View {
        Section {
            if let totals = detail.tokens, detail.selectedModel == nil {
                TokenMixBar(segments: TokenMixSegment.segments(input: totals.input, output: totals.output, breakdown: totals.breakdown,
                                                cacheRead: totals.cacheInput, cacheWrite: totals.cacheWrite),
                            help: totals.breakdown.details)
            }
            ModelUsageTable(models: models)
            if detail.partial {
                Label("Sample limit reached. Totals are partial.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(SettingsStyle.caution)
            }
        } header: {
            HStack {
                Text(detail.selectedModel.map { "Snapshot: \($0)" } ?? "Snapshot: today by model")
                Spacer()
                Button("Close") { model.liveUsageDetail = nil }.buttonStyle(.link)
            }
        } footer: {
            SettingsFootnote("Captured \(detail.observedAt.formatted(date: .omitted, time: .shortened)), \(detail.zone).")
        }
    }
}

struct ModelUsageTable: View {
    let models: [NotchModelRow]

    init(models: [NotchModelRow]) { self.models = models }
    init(models: [ObservedModelTokens]) { self.models = models.map(NotchModelRow.init) }

    var body: some View {
        MetricTable(columns: [
            TableColumnSpec(title: "Model", alignment: .leading),
            TableColumnSpec(title: "Calls"),
            TableColumnSpec(title: "Input"),
            TableColumnSpec(title: "Output"),
            TableColumnSpec(title: "Cache read"),
            TableColumnSpec(title: "Cache write"),
            TableColumnSpec(title: "Total")
        ], rows: models) { item, column in
            switch column {
            case 0:
                Text(item.title).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.breakdown.details)
            case 1: Text(item.calls.formatted()).foregroundStyle(.secondary)
            case 2: Text(MetricFormat.tokens(item.input))
            case 3: Text(MetricFormat.tokens(item.output))
            case 4: Text(item.cacheCoverage.displayValue(compact: true)).help(item.cacheCoverage.details)
            case 5: Text(item.breakdown.write.displayValue(compact: true)).help(item.breakdown.write.details)
            default: Text(MetricFormat.tokens(item.tokens)).fontWeight(.medium)
            }
        }
    }
}
