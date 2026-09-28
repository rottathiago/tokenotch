import TokenotchCore
import SwiftUI

struct SessionNoticeList: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject var attention: SessionAttentionController
    var target: SessionDetailTarget?
    var pendingOnly = false

    private var notices: [SessionNotice] {
        attention.state.notices.filter {
            (target == nil || $0.sessionID == target?.noticeSessionID) && (!pendingOnly || $0.disposition == .pending)
        }
    }

    var body: some View {
        if let error = attention.error {
            LabeledContent {
                Button("Retry") { attention.retry() }
            } label: {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution)
            }
        }
        if attention.state.evictedSessions > 0 && target == nil {
            SettingsFootnote("\(attention.state.evictedSessions) older sessions were removed at capacity, not resolved.")
        }
        if notices.isEmpty && target != nil {
            Text("No notices for this session.").foregroundStyle(.secondary)
        }
        ForEach(notices) { notice in
            row(notice)
        }
    }

    private func row(_ notice: SessionNotice) -> some View {
        let signal = SessionSignal(notice.kind)
        let stale = notice.isStale(now: model.clock) || attention.isRestored(notice)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: signal.symbol)
                .foregroundStyle(signal.settingsColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(notice.kind.title).fontWeight(notice.viewedAt == nil && notice.disposition == .pending ? .semibold : .regular)
                    if stale { StatusBadge(text: "Stale", tone: .neutral) }
                }
                HStack(spacing: 6) {
                    Text("\(notice.source == .cli ? "Copilot CLI" : "VS Code") \(notice.sessionID.prefix(6))")
                    Text(notice.observedAt.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary)
                if notice.disposition != .pending || notice.kind.isRequest {
                    Text(status(notice)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if target == nil {
                Button("View") {
                    let live = model.sessions.first {
                        $0.source == notice.source &&
                            attention.state.sessionID(source: $0.source, hash: $0.key) == notice.sessionID
                    }
                    attention.markViewed([notice.id])
                    model.selectedSession = SessionDetailTarget(source: notice.source,
                        noticeSessionID: notice.sessionID, liveHash: live?.key)
                    model.usageNavigation = UUID()
                }
            } else if notice.viewedAt == nil && notice.disposition == .pending {
                Button("Mark as Viewed") { attention.markViewed([notice.id]) }
            }
            if notice.disposition == .pending {
                Button {
                    attention.dismiss(notice.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss. This doesn't mean the underlying task succeeded.")
                .accessibilityLabel("Dismiss notice")
            }
        }
        .padding(.vertical, 2)
    }

    private func status(_ notice: SessionNotice) -> String {
        switch notice.disposition {
        case .pending:
            return notice.kind.isRequest ? "Response status unknown" : notice.viewedAt == nil ? "New" : "Viewed"
        case .dismissed: return "Dismissed, not confirmed resolved"
        case .resolved: return "Resolved by later activity"
        case .superseded: return "Superseded by later activity"
        }
    }
}

struct SessionNoticeControls: View {
    @ObservedObject var attention: SessionAttentionController
    var showsManagement = true
    private final class Confirmation: ObservableObject {
        @Published var enable = false
        @Published var disable = false
        @Published var clear = false
    }
    @StateObject private var confirmation = Confirmation()

    var body: some View {
        Toggle(isOn: Binding(
            get: { attention.saving },
            set: { if $0 { confirmation.enable = true } else { confirmation.disable = true } })) {
            Text("Remember after quitting")
            Text("Keeps notice types, times and viewed state for up to 100 sessions. Closed notices expire after 7 days.")
        }
        .alert("Remember new session notices?", isPresented: $confirmation.enable) {
            Button("Start Fresh and Turn On") { attention.enable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current notices will be cleared. Only new notices are saved on this Mac from now on.")
        }
        .alert("Stop remembering and delete saved notices?", isPresented: $confirmation.disable) {
            Button("Delete Saved Notices", role: .destructive) { attention.disableAndDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current notices stay until Tokenotch quits. Saved timelines and usage history aren't changed.")
        }
        if let error = attention.error {
            LabeledContent {
                Button("Retry") { attention.retry() }
            } label: {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.caution)
            }
        }
        if attention.state.evictedSessions > 0 {
            Text("Some older notices were removed at the session limit, not resolved.")
                .font(.caption).foregroundStyle(SettingsStyle.caution)
        }
        if showsManagement {
            LabeledContent {
                Button("Clear…") { confirmation.clear = true }
            } label: {
                Text("Clear notices")
                Text("Deletes saved and current notices. New notices still appear.")
            }
            .alert("Clear all session notices?", isPresented: $confirmation.clear) {
                Button("Clear Notices", role: .destructive) { attention.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes saved and current notices, their viewed state and local identity. Timelines and usage history aren't changed.")
            }
        }
    }
}
