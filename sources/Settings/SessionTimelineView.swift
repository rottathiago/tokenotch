import TokenotchCore
import SwiftUI

extension TimelineRetention {
    var title: String { rawValue == 1 ? "1 day" : "\(rawValue) days" }
}

extension SessionTimelineController {
    var hasSavedTimelines: Bool { !sessions.isEmpty || (archive?.sessionCount ?? 0) > 0 }

    /// Short, user-facing recording state shown under the toggle.
    var displayStatus: String {
        if let error { return error }
        if !enabled { return hasSavedTimelines ? "Paused. Saved timelines are kept." : "Off. Nothing is saved." }
        return recording ? "Recording new sessions" : "Waiting for Copilot CLI or VS Code to connect"
    }

    var privacySummary: String {
        if error != nil { return "Unavailable" }
        if !enabled { return hasSavedTimelines ? "Paused, kept \(retention.title)" : "Off" }
        return "On, kept \(retention.title)"
    }
}

private final class SessionsTabState: ObservableObject {
    @Published var deletion = false
    @Published var browsing = false
    @Published var pendingRetention: TimelineRetention?
}

private final class TimelineRecordingConfirmation: ObservableObject {
    @Published var consent = false
}

struct TimelineRecordingControls: View {
    @ObservedObject var timeline: SessionTimelineController
    @StateObject private var confirmation = TimelineRecordingConfirmation()

    var body: some View {
        Toggle(isOn: Binding(get: { timeline.enabled }, set: { value in
            if value { confirmation.consent = true } else { timeline.setEnabled(false) }
        })) {
            Text("Record session timelines")
            Text(timeline.error == nil ? timeline.displayStatus : "Unavailable")
        }
        .confirmationDialog("Save session timelines on this Mac?", isPresented: $confirmation.consent, titleVisibility: .visible) {
            Button("Turn On Timelines") { timeline.setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tokenotch records model calls, context, response times and lifecycle events for new sessions, kept for \(timeline.retention.title). No prompts, responses, code or file paths are saved. Earlier sessions can't be added.")
        }
        if let error = timeline.error {
            LabeledContent {
                Button("Retry") { timeline.retry() }
            } label: {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(SettingsStyle.caution)
            }
        }
    }
}

struct SessionTimelineView: View {
    @ObservedObject var timeline: SessionTimelineController
    @ObservedObject var attention: SessionAttentionController
    @StateObject private var state = SessionsTabState()

    var body: some View {
        Form {
            Section {
                TimelineRecordingControls(timeline: timeline)
                retentionPicker
                LabeledContent {
                    Button("Browse…") { state.browsing = true }
                        .disabled(!timeline.hasSavedTimelines)
                } label: {
                    Text("Saved timelines")
                    Text(timeline.hasSavedTimelines ? "See what each session did, step by step." : "None saved yet")
                }
                LabeledContent {
                    Button("Delete…", role: .destructive) { state.deletion = true }
                        .disabled(!timeline.hasSavedTimelines && timeline.error == nil)
                } label: {
                    Text("Delete all timelines")
                    Text("Usage history and live data aren't affected.")
                }
            } header: {
                Text("Session timelines")
            } footer: {
                SettingsFootnote("Saves model, token, timing and lifecycle details only. Never prompts, code or file paths.")
            }

            Section {
                SessionNoticeControls(attention: attention)
            } header: {
                Text("Session notices")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Keep timelines for a shorter time?", isPresented: Binding(
            get: { state.pendingRetention != nil }, set: { if !$0 { state.pendingRetention = nil } }), titleVisibility: .visible) {
            Button("Delete Older Events", role: .destructive) {
                if let value = state.pendingRetention { timeline.setRetention(value) }
                state.pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { state.pendingRetention = nil }
        } message: {
            Text("Events older than \(state.pendingRetention?.title ?? timeline.retention.title) will be deleted now. This can't be undone.")
        }
        .confirmationDialog("Delete all saved session timelines?", isPresented: $state.deletion, titleVisibility: .visible) {
            Button("Delete Session Timelines", role: .destructive) { timeline.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. If recording is on, it continues with an empty timeline. Usage history and live data aren't affected.")
        }
        .sheet(isPresented: Binding(get: { state.browsing || timeline.selectedSession != nil },
                                   set: { if !$0 { state.browsing = false; timeline.selectedSession = nil } })) {
            SavedTimelinesSheet(timeline: timeline, browsing: $state.browsing)
        }
    }

    private var retentionPicker: some View {
        Picker(selection: Binding(get: { timeline.retention }, set: { value in
            if value.rawValue < timeline.retention.rawValue && timeline.hasSavedTimelines { state.pendingRetention = value }
            else { timeline.setRetention(value) }
        })) {
            ForEach(TimelineRetention.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Keep timelines for")
            Text("Older events are removed automatically.")
        }
    }
}

/// Saved-session list and single-session detail share one sheet so the list can navigate into a timeline and back.
private struct SavedTimelinesSheet: View {
    @ObservedObject var timeline: SessionTimelineController
    @Binding var browsing: Bool

    private var groups: [(day: Date, sessions: [TimelineSession])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: timeline.sessions) { calendar.startOfDay(for: $0.last) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day, default: []].sorted { $0.last > $1.last })
        }
    }

    var body: some View {
        Group {
            if let selected = timeline.selectedSession {
                detail(selected)
            } else {
                list
            }
        }
        .frame(width: 620, height: 640)
    }

    private func close() {
        browsing = false
        timeline.selectedSession = nil
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved timelines").font(.title3.weight(.semibold))
                    Text("Kept for \(timeline.retention.title)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form {
                if timeline.sessions.isEmpty {
                    Section {
                        EmptyStateView(symbol: "clock", title: "No saved timelines",
                                       message: timeline.enabled ? "New Copilot sessions appear here as they run."
                                           : "Turn on recording to save timelines for new sessions.")
                    }
                }
                ForEach(groups, id: \.day) { group in
                    Section(dayTitle(group.day)) {
                        ForEach(group.sessions) { session in sessionRow(session) }
                    }
                }
                if timeline.sessions.count < (timeline.archive?.sessionCount ?? 0) {
                    Section {
                        HStack {
                            Spacer()
                            Button("Load More Sessions") { Task { await timeline.loadMoreSessions() } }
                            Spacer()
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func detail(_ selected: String) -> some View {
        let session = timeline.sessions.first { $0.id == selected }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if browsing {
                    Button {
                        timeline.selectedSession = nil
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back to saved timelines")
                    .accessibilityLabel("Back to saved timelines")
                }
                if let session {
                    SettingsIconTile(symbol: session.source.symbol,
                                     color: session.source == .cli ? .gray : .blue, size: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(session?.source.shortTitle ?? "Session") \(selected.prefix(8))")
                        .font(.title3.weight(.semibold))
                    if let session {
                        Text("\(session.first.formatted(date: .abbreviated, time: .shortened)) – \(session.last.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            if timeline.archive?.pruned == true || timeline.archive?.interrupted == true || session?.truncated == true {
                Label("This timeline may be incomplete.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(SettingsStyle.caution)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if let error = timeline.error {
                Text(error).font(.caption).foregroundStyle(SettingsStyle.caution)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider()
            ScrollView {
                TimelineEventsView(timeline: timeline, session: selected)
                    .id(selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func sessionRow(_ session: TimelineSession) -> some View {
        Button {
            timeline.selectedSession = session.id
        } label: {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: session.source.symbol, color: session.source == .cli ? .gray : .blue, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.source.shortTitle).fontWeight(.medium)
                        Text(session.id.prefix(8)).foregroundStyle(.secondary)
                    }
                    Text("\(session.count.formatted()) events\(session.truncated ? ", truncated" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timeRange(session)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }

    private func timeRange(_ session: TimelineSession) -> String {
        let start = session.first.formatted(date: .omitted, time: .shortened)
        let end = session.last.formatted(date: .omitted, time: .shortened)
        return start == end ? start : "\(start) – \(end)"
    }
}

private final class TimelineEventsState: ObservableObject {
    @Published var events: [TimelineEvent] = []
    @Published var hasMore = false
    @Published var loading = false
    @Published var error: String?
    @Published var loadingMore = false
}

private struct TimelineEventsView: View {
    @ObservedObject var timeline: SessionTimelineController
    let session: String
    @StateObject private var state = TimelineEventsState()
    private var events: [TimelineEvent] { state.events }
    private var hasMore: Bool { state.hasMore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.loading { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20) }
            if let error = state.error { Text(error).foregroundStyle(SettingsStyle.caution) }
            if !state.loading && events.isEmpty && state.error == nil {
                EmptyStateView(symbol: "clock", title: "No saved events",
                               message: "Recording may have been off, or these events expired or were deleted.")
            }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                eventRow(event, last: index == events.count - 1 && !hasMore)
            }
            if hasMore {
                HStack {
                    Spacer()
                    Button(state.loadingMore ? "Loading…" : "Load More Events") { Task { await loadMore() } }
                        .disabled(state.loadingMore || state.loading)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .task(id: timeline.revision) { await load() }
    }

    private func eventRow(_ event: TimelineEvent, last: Bool) -> some View {
        let style = eventStyle(event)
        return HStack(alignment: .top, spacing: 12) {
            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
                .padding(.top, 2)
            VStack(spacing: 0) {
                Image(systemName: style.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(style.color, in: Circle())
                if !last {
                    Rectangle().fill(.separator).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(event)).fontWeight(.medium)
                ForEach(details(event), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let note = annotation(event) {
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 14)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func eventStyle(_ event: TimelineEvent) -> (symbol: String, color: Color) {
        switch event.kind {
        case .usage: return ("sparkle", SettingsStyle.brand)
        case .context, .contextInvalidated: return ("gauge.with.dots.needle.50percent", .teal)
        case .compaction: return ("arrow.down.right.and.arrow.up.left", event.compactionSuccess == false ? .red : .indigo)
        case .started: return ("play.fill", .gray)
        case .working, .active: return ("circle.dotted", .blue)
        case .stopped: return ("stop.fill", .purple)
        case .failed, .unrecoverableError: return ("xmark", .red)
        case .inputRequested, .approvalRequested: return ("hand.raised.fill", .orange)
        case .ended, .cancelled, .idle: return ("minus", .gray)
        }
    }

    private func displayTitle(_ event: TimelineEvent) -> String {
        switch event.kind {
        case .usage: return event.model ?? "Model call"
        case .context:
            if let count = event.contextTokens, let limit = event.contextLimit, limit > 0 {
                return "Context at \(MetricFormat.percent(Double(count) / Double(limit)))"
            }
            return "Context reading"
        case .stopped: return "Stopped"
        case .working: return "Working"
        default: return event.title
        }
    }

    private func details(_ event: TimelineEvent) -> [String] {
        var lines: [String] = []
        if event.kind == .usage {
            var parts = ["\(event.input.map(MetricFormat.tokens) ?? "—") input", "\(event.output.map(MetricFormat.tokens) ?? "—") output"]
            if let cache = event.cacheCoverage, cache.hasValue { parts.append("\(cache.displayValue(compact: true)) cache read") }
            if let write = event.breakdown?.write, write.hasValue { parts.append("\(write.displayValue(compact: true)) cache write") }
            lines.append(parts.joined(separator: ", "))
            if event.firstTokenMs != nil || event.durationMs != nil {
                lines.append("First token \(MetricFormat.latency(event.firstTokenMs)), total \(MetricFormat.latency(event.durationMs))")
            }
        }
        if event.kind == .context, let count = event.contextTokens, let limit = event.contextLimit {
            lines.append("\(count.formatted()) of \(limit.formatted()) tokens")
        }
        if event.kind == .compaction, event.before != nil || event.after != nil {
            lines.append("\(event.before.map(MetricFormat.tokens) ?? "—") → \(event.after.map(MetricFormat.tokens) ?? "—") tokens")
        }
        if event.kind == .stopped { lines.append("The turn ended. This doesn't confirm the task succeeded.") }
        return lines
    }

    private func annotation(_ event: TimelineEvent) -> String? {
        let preceding = events.filter { $0.kind == event.kind && $0.timestamp < event.timestamp }.last
        let ambiguous = events.filter { $0.kind == event.kind && $0.timestamp == event.timestamp }.count != 1
            || preceding.map { prior in events.filter { $0.kind == prior.kind && $0.timestamp == prior.timestamp }.count != 1 } == true
        // Do not derive a transition across a page boundary whose tied rows are not loaded yet.
        let pageBoundary = hasMore && events.last?.timestamp == event.timestamp
        return event.annotation(previous: preceding, timestampIsAmbiguous: ambiguous || pageBoundary)
    }
    private func load() async {
        state.loading = true
        state.error = nil
        let desiredCount = max(100, events.count)
        do {
            var loaded: [TimelineEvent] = []
            var more = false
            repeat {
                let page = try await timeline.readEvents(session: session, after: loaded.last)
                try Task.checkCancellation()
                loaded += page?.events ?? []
                more = page?.hasMore ?? false
            } while more && loaded.count < desiredCount
            state.events = loaded
            state.hasMore = more
            state.loading = false
        } catch is CancellationError {
            // A newer revision owns the view.
        } catch {
            guard !Task.isCancelled else { return }
            state.error = (error as? TimelineError)?.rawValue ?? TimelineError.storage.rawValue
            state.events = []
            state.loading = false
        }
    }
    private func loadMore() async {
        state.loadingMore = true
        let revision = timeline.revision
        defer { state.loadingMore = false }
        do {
            let page = try await timeline.readEvents(session: session, after: events.last)
            guard revision == timeline.revision else { return }
            state.events += page?.events ?? []
            state.hasMore = page?.hasMore ?? false
        } catch {
            guard revision == timeline.revision else { return }
            state.error = (error as? TimelineError)?.rawValue ?? TimelineError.storage.rawValue
        }
    }
}
