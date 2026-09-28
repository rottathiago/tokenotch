import AppKit
import TokenotchCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(model: model)
                .navigationTitle(model.settingsTab.title)
        }
        .tint(SettingsStyle.brand)
        .sheet(isPresented: Binding(get: { model.showOnboarding }, set: { visible in
            if !visible { model.pauseOnboarding() }
        })) { OnboardingView(model: model) }
    }
}

struct SettingsSidebar: View {
    @ObservedObject var model: TokenotchModel

    private var selection: Binding<SettingsTab?> {
        Binding(get: { model.settingsTab }, set: { if let value = $0 { model.settingsTab = value } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(Array(SettingsTab.sidebarGroups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group, id: \.self) { tab in
                        Label {
                            Text(tab.title)
                        } icon: {
                            SettingsIconTile(symbol: tab.symbol, color: tab.tileColor)
                        }
                        .tag(tab)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        .safeAreaInset(edge: .bottom, spacing: 0) { versionFooter }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            TokenotchMarkView()
                .frame(width: 32, height: 32)
            Text("Tokenotch").font(.headline).lineLimit(1).fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var versionFooter: some View {
        Text(AppVersion.display)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

struct SettingsDetail: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.onboardingComplete {
                HStack {
                    Text("Your setup guide is ready to resume.").font(.callout)
                    Spacer()
                    Button("Resume Setup") { model.resumeOnboarding() }
                }
                .padding()
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(SettingsStyle.caution)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(SettingsStyle.caution.opacity(0.1))
            }
            switch model.settingsTab {
            case .usage: UsageTabView(model: model)
            case .history: UsageHistoryView(history: model.history)
            case .sessions: SessionTimelineView(timeline: model.timeline, attention: model.attention)
            case .connections: ConnectionsView(model: model)
            case .notifications: NotificationSettingsView(model: model)
            case .appearance: GeneralSettingsView(model: model)
            case .privacy: PrivacySettingsView(model: model)
            case .about: AboutSettingsView(updates: model.updates)
            }
        }
    }
}

struct NotificationPermissionControls: View {
    @ObservedObject var model: TokenotchModel

    private var enabled: Binding<Bool> {
        Binding(get: { model.options.notifications.enabled }, set: { value in
            if value && model.notificationStatus == "Not requested" { model.requestNotifications() }
            else { model.options.notifications.enabled = value }
        })
    }

    private var permissionDenied: Bool { model.notificationStatus.hasPrefix("Denied") }

    var body: some View {
        Group {
            Toggle(isOn: enabled) {
                Text("Allow notifications")
                Text("Get notified when a Copilot session needs you.")
            }
            .disabled(model.managedMute)
            if model.managedMute {
                Label("Turned off by your organization.", systemImage: "lock.fill").foregroundStyle(.secondary)
            } else if permissionDenied {
                LabeledContent {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                } label: {
                    Label("Notifications are blocked in macOS", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SettingsStyle.caution)
                }
            } else if model.notificationStatus == "Not requested" && model.options.notifications.enabled {
                LabeledContent("macOS permission is still needed") {
                    Button("Allow Banners in macOS") { model.requestNotifications() }
                }
            }
            if model.notificationStatus == "Permission request failed" {
                LabeledContent(model.notificationStatus) {
                    Button("Retry permission") { model.requestNotifications() }
                        .disabled(model.managedMute)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
        }
    }
}

struct NotificationSettingsView: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        Form {
            Section { NotificationPermissionControls(model: model) }

            Section("Delivery") {
                Toggle(isOn: $model.options.notifications.desktop) {
                    Text("Show banners")
                    Text("macOS controls which display shows desktop banners.")
                }
                Toggle(isOn: $model.options.notifications.sound) {
                    Text("Play sound")
                    Text("Play once per notification, independently of macOS banners. Uses your current audio output and volume.")
                }
                Toggle(isOn: $model.options.notifications.expandNotch) {
                    Text("Open the session card")
                    Text("Expand every visible notch when a notification arrives. Enable Show on all displays in General for multiple displays.")
                }
                if let error = model.notificationSoundError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SettingsStyle.caution)
                }
                if model.notificationStatus.hasPrefix("Desktop delivery") {
                    Label(model.notificationStatus, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SettingsStyle.caution)
                }
                LabeledContent("Test delivery") {
                    Button("Send Test Notification") { model.testNotification() }
                }
            }
            .disabled(!model.options.notifications.enabled || model.managedMute)

            Section {
                category("Session stopped", "A session finished its turn. This doesn't confirm the task succeeded.", .stopped)
                category("Input or approval needed", "The session is asking for your response. Copilot CLI only.", .attention)
                category("Session error", "The session hit an error it can't recover from. Copilot CLI only.", .failed)
                category("High context usage", "The context window crossed 80%. Copilot CLI only.", .context)
            } header: {
                Text("Sessions")
            }
            .disabled(!model.options.notifications.enabled || model.managedMute)

            Section {
                category("Incident reported", "GitHub reports a Copilot service problem.", .incident)
                category("Incident resolved", "GitHub confirms the problem is fixed.", .recovery)
            } header: {
                Text("GitHub service")
            } footer: {
                SettingsFootnote("Requires GitHub status checks, in Privacy.")
            }
            .disabled(!model.options.notifications.enabled || model.managedMute)

            Section {
                LabeledContent("Pause notifications") {
                    if let until = model.options.notifications.snoozedUntil, until > model.clock {
                        HStack(spacing: 8) {
                            Text("Until \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            Button("Resume") { model.options.notifications.snoozedUntil = nil }
                        }
                    } else {
                        Menu("Pause") {
                            Button("For 30 minutes") { model.snooze(minutes: 30) }
                            Button("For 1 hour") { model.snooze(minutes: 60) }
                            Button("For 4 hours") { model.snooze(minutes: 240) }
                        }
                        .fixedSize()
                    }
                }
                Toggle("Quiet hours", isOn: $model.options.notifications.quietEnabled)
                if model.options.notifications.quietEnabled {
                    DatePicker("From", selection: minuteBinding(\.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minuteBinding(\.quietEnd), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Quiet time")
            } footer: {
                SettingsFootnote("Notifications during quiet time are skipped, not delivered later.")
            }

        }
        .formStyle(.grouped)
    }

    private func category(_ title: String, _ detail: String, _ value: NoticeCategory) -> some View {
        Toggle(isOn: Binding(
            get: { model.options.notifications.categories.contains(value) },
            set: { enabled in
                if enabled { model.options.notifications.categories.insert(value) }
                else { model.options.notifications.categories.remove(value) }
            }
        )) {
            Text(title)
            Text(detail)
        }
    }

    private func minuteBinding(_ path: WritableKeyPath<NotificationPreferences, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = model.options.notifications[keyPath: path]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            model.options.notifications[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.options.showNotch) {
                    Text("Show notch")
                    Text("An ambient Copilot indicator at the edge of your screen.")
                }
                Group {
                    Toggle(isOn: $model.options.autoHideNotch) {
                        Text("Collapse when idle")
                        Text("Hover to expand, move away to collapse. Click to keep it open.")
                    }
                    Toggle("Hide in full-screen apps", isOn: $model.options.foldsForFullScreen)
                }
                .disabled(!model.options.showNotch)
            } header: {
                Text("Notch")
            }

            Section {
                Picker("Screen edge", selection: $model.options.edge) {
                    ForEach(NotchEdge.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show on all displays", isOn: $model.options.allDisplays)
                Picker("Display", selection: Binding(get: { model.options.displayID ?? "" },
                                                     set: { model.options.displayID = $0.isEmpty ? nil : $0 })) {
                    Text("Active display").tag("")
                    ForEach(DisplayOption.connected) { Text($0.name).tag($0.id) }
                }
                .disabled(model.options.allDisplays)
                Slider(value: $model.options.scale, in: 0.75...1.5) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller").accessibilityLabel("Smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger").accessibilityLabel("Larger")
                }
            } header: {
                Text("Position")
            } footer: {
                SettingsFootnote("Option-drag the notch to move it along the edge.")
            }
            .disabled(!model.options.showNotch)

            Section("Charts") {
                Picker("Time format", selection: $model.options.timeFormat) {
                    ForEach(TimeFormat.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Startup") {
                Toggle("Open Tokenotch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled },
                                                           set: { model.setLaunchAtLogin($0) }))
                Text(model.loginItemStatus).font(.callout).foregroundStyle(.secondary)
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                Button("Review Setup Guide") { model.reviewOnboarding() }
            }
            if model.preferencesUnreadable {
                Section("Preferences need attention") {
                    Text("Saved preferences could not be read. Changes will not overwrite them.")
                    Button("Reset Preferences, Keeping a Recovery Copy") { model.resetUnreadablePreferences() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItemStatus() }
    }
}

private struct SessionsPrivacySummary: View {
    @ObservedObject var timeline: SessionTimelineController
    @ObservedObject var attention: SessionAttentionController

    var body: some View {
        DescribedRow(title: "Session timelines",
                     detail: "Model, token, timing and lifecycle details per session. No content.",
                     symbol: "list.bullet.rectangle") {
            Text(timeline.privacySummary).foregroundStyle(.secondary)
        }
        DescribedRow(title: "Session notices",
                     detail: "Notice types, times and viewed state.",
                     symbol: "bell") {
            Text(attention.saving ? "Kept after quitting" : "Cleared on quit").foregroundStyle(.secondary)
        }
    }
}

private final class PrivacyConfirmation: ObservableObject {
    @Published var clear = false
}

struct PrivacySettingsView: View {
    @ObservedObject var model: TokenotchModel
    @StateObject private var confirmation = PrivacyConfirmation()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    SettingsIconTile(symbol: "lock.shield.fill", color: .indigo, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your data stays on this Mac").font(.headline)
                        Text("Tokenotch has no server of its own and sends no analytics. It reads usage numbers from your Copilot clients, never the content of your work.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("What Tokenotch reads") {
                DescribedRow(title: "Session activity",
                             detail: "Whether a session is working, stopped or waiting for you. Session IDs are hashed.",
                             symbol: "waveform.path.ecg")
                DescribedRow(title: "Usage numbers",
                             detail: "Model names, token counts, context size and response times.",
                             symbol: "number")
                DescribedRow(title: "Never kept",
                             detail: "Prompts, responses, code, tool arguments, file paths and repository names are discarded before anything is saved.",
                             symbol: "eye.slash", symbolColor: SettingsStyle.good)
            }

            Section {
                DescribedRow(title: "GitHub account",
                             detail: "Sign-in and quota go through the official Copilot CLI. Tokenotch never sees your token.",
                             symbol: "person.crop.circle") {
                    StatusBadge(text: model.accountSnapshot != nil ? "Connected" : "Off",
                                tone: model.accountSnapshot != nil ? .good : .neutral)
                }
                DescribedRow(title: "GitHub status",
                             detail: "Checks githubstatus.com every five minutes for Copilot incidents.",
                             symbol: "antenna.radiowaves.left.and.right") {
                    Toggle("GitHub status", isOn: $model.options.healthEnabled)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(model.managedHealthDisabled)
                }
                if model.options.healthEnabled {
                    LabeledContent {
                        Button("Open GitHub Status") { model.openStatus() }
                    } label: {
                        Text(model.health)
                        if let date = model.healthObservedAt {
                            Text("Checked \(date.formatted(.relative(presentation: .named)))")
                        }
                    }
                    .padding(.leading, 32)
                }
            } header: {
                Text("Network")
            } footer: {
                SettingsFootnote("No analytics or crash reports are sent. Check for Updates contacts GitHub only when you choose it; GitHub receives ordinary connection metadata.")
            }

            Section {
                HistoryControls(history: model.history)
            } header: {
                Text("Usage history")
            } footer: {
                SettingsFootnote("Daily totals are kept until you delete them. Hourly detail is kept for 7 days.")
            }

            Section {
                SessionsPrivacySummary(timeline: model.timeline, attention: model.attention)
                LabeledContent {
                    Button("Manage in Sessions") { model.settingsTab = .sessions }
                } label: {
                    Text("Recording, retention and deletion")
                }
            } header: {
                Text("Sessions")
            }

            Section {
                DescribedRow(title: "Live data",
                             detail: "Current sessions, token counts and notices, held in memory for up to 24 hours.",
                             symbol: "memorychip") {
                    Button("Clear…") { confirmation.clear = true }
                }
            } header: {
                Text("Temporary data")
            }

            Section {
                DisclosureGroup("Diagnostic report") {
                    Text(model.diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                LabeledContent {
                    Button("Copy Report") { model.copyDiagnostics() }
                } label: {
                    Text("Share with support")
                    Text("Statuses only. Excludes your account name and any content.")
                }
            } header: {
                Text("Diagnostics")
            }

            Section {
                LabeledContent {
                    Button("Open Connections") { model.settingsTab = .connections }
                } label: {
                    Text("Stop collecting")
                    Text("Disconnect a client to stop new observations. Saved data stays until you delete it.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear live data?", isPresented: $confirmation.clear, titleVisibility: .visible) {
            Button("Clear Live Data", role: .destructive) { model.clearLocalHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes current sessions, token counts, session notices and notification records. Saved usage history and timelines are kept.")
        }
    }
}
