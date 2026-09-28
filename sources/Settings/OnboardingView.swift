import AppKit
import TokenotchCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var integration: VSCodeIntegrationController

    init(model: TokenotchModel) {
        self.model = model
        integration = model.vscode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                TokenotchMarkView().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.setupStep.title).font(.title2.weight(.semibold))
                    Text("Step \(model.setupStep.number) of \(OnboardingStep.allCases.count)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.setupStep {
                    case .welcome: welcome
                    case .connections: connections
                    case .preferences: OnboardingPreferences(model: model)
                    case .complete: OnboardingResult(model: model)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(SettingsStyle.caution)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 4)
                .id(model.setupStep)
            }
            .defaultScrollAnchor(.top)
            if let message = model.onboardingMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(SettingsStyle.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if model.setupStep != .complete {
                    Button("Pause setup") { model.pauseOnboarding() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.setupStep == .connections || model.setupStep == .preferences {
                    Button("Back") { model.backOnboarding() }
                }
                Button(primaryAction) { model.advanceOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvanceOnboarding)
            }
        }
        .padding(24)
        .frame(width: 620, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(SettingsStyle.brand)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshConnectionInstallations()
        }
    }

    private var primaryAction: String {
        switch model.setupStep {
        case .welcome: return "Get started"
        case .connections: return "Continue"
        case .preferences: return "Finish setup"
        case .complete: return "Start using Tokenotch"
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Visibility into your AI coding usage and patterns").font(.headline)
            Text("Track token consumption and model usage across your coding sessions. Run multiple coding agents at once and know when a session needs your action or attention.")
            Label("Connect Copilot CLI or Visual Studio Code on this Mac.", systemImage: "point.3.connected.trianglepath.dotted")
            Label("Prompts, responses and code are not saved.", systemImage: "lock.shield")
            Label("Notifications, saved history and account sign-in are your choice.", systemImage: "slider.horizontal.3")
            Text("We'll configure at least one client together. You can pause and come back to the same step.")
            Text("Move Tokenotch to Applications before connecting. Tokenotch sends no analytics and makes no automatic update checks. A stopped turn is not proof a task succeeded; local token observations are not your bill.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a client to set up. One configured client is enough; you can connect both.")
            HStack {
                ForEach(Client.allCases) { client in
                    Button { model.selectOnboardingClient(client) } label: {
                        HStack {
                            Label(client == .cli ? "Copilot CLI" : "Visual Studio Code", systemImage: client.symbol)
                            if model.onboarding.activeClient == client {
                                Image(systemName: "checkmark").accessibilityHidden(true)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.onboarding.activeClient == client ? SettingsStyle.brand : .secondary)
                    .accessibilityValue(model.onboarding.activeClient == client ? "Selected" : "Not selected")
                }
            }
            if model.managedHooksDisabled {
                Label("Client connections are turned off by your organization. Pause setup and contact your administrator.",
                      systemImage: "lock.fill").foregroundStyle(SettingsStyle.caution)
            }
            if let client = model.onboarding.activeClient {
                OnboardingConnectionStatus(model: model, client: client)
                ConnectionSetupContent(model: model, client: client).id(client)
                Text("Successful configuration lets you continue. Reload the client as instructed; activity can be verified later.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Select Copilot CLI or Visual Studio Code above to see the next step.")
                    .foregroundStyle(.secondary)
            }
            if integration.isWorking {
                Text("Approval or installation may continue while you pause. Return here to see its result; pausing does not remove any settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup("Optional: GitHub account quota") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("See account-wide quota in addition to local activity. This is optional and does not replace connecting a client.")
                        .font(.callout).foregroundStyle(.secondary)
                    AccountConnectionControls(model: model)
                    Text("Sign-in uses the official Copilot CLI and your browser. Tokenotch never sees your token.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }
}

private struct OnboardingConnectionStatus: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var integration: VSCodeIntegrationController
    let client: Client

    init(model: TokenotchModel, client: Client) {
        self.model = model
        integration = model.vscode
        self.client = client
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(client == .cli ? "Copilot CLI" : "Visual Studio Code") {
                StatusBadge(text: model.isClientConfigured(client) ? "Configured" : "Not configured",
                            symbol: model.isClientConfigured(client) ? "checkmark.circle" : "circle.dotted",
                            tone: model.isClientConfigured(client) ? .good : .neutral)
            }
            if model.isClientConfigured(client) {
                let readiness = ConnectionReadiness.activity(installed: true, approved: true,
                    observed: model.lastActivityEvent[client], now: model.clock)
                Label(readiness == .waiting ? "Waiting for first activity" : readiness.title, systemImage: readiness.symbol)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.connectionSetupErrors[client] {
                Text(error).font(.caption).foregroundStyle(SettingsStyle.caution)
            }
            if client == .vscode {
                if integration.isWorking || [.blocked, .failed, .cancelled].contains(integration.phase) {
                    Text(integration.status).font(.caption).foregroundStyle(SettingsStyle.caution)
                }
                if let error = integration.error {
                    Text(error).font(.caption).foregroundStyle(SettingsStyle.caution)
                }
            }
        }
    }
}

private struct OnboardingPreferences: View {
    @ObservedObject var model: TokenotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Everything here is optional. Keep the defaults to use Tokenotch without notifications or saved history.")
            NotificationPermissionControls(model: model)
            Text("Sound and automatic session-card expansion remain separate choices in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("What stays on this Mac").font(.headline)
            HistoryControls(history: model.history, showsManagement: false)
            TimelineRecordingControls(timeline: model.timeline)
            Text("Session notices").font(.headline)
            SessionNoticeControls(attention: model.attention, showsManagement: false)
        }
    }
}

private struct OnboardingResult: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var integration: VSCodeIntegrationController
    @ObservedObject private var history: HistoryController
    @ObservedObject private var timeline: SessionTimelineController
    @ObservedObject private var attention: SessionAttentionController

    init(model: TokenotchModel) {
        self.model = model
        integration = model.vscode
        history = model.history
        timeline = model.timeline
        attention = model.attention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Welcome to Tokenotch. Your setup is complete.", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(SettingsStyle.good)
            ForEach(Client.allCases) { client in
                OnboardingConnectionStatus(model: model, client: client)
            }
            Text("Reload your configured client and use Copilot normally. Tokenotch will show activity when it arrives. Configured does not mean delivery has been verified.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Your optional choices").font(.headline)
            LabeledContent("VS Code model & token usage", value: usageStatus)
            LabeledContent("GitHub account quota", value: accountStatus)
            if model.accountStatus != "Not connected" && model.accountSnapshot == nil {
                Text(model.accountStatus).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Notifications", value: model.options.notifications.enabled ? model.notificationStatus : "Off")
            LabeledContent("Usage history", value: history.error ?? (history.enabled ? "On" : "Off"))
            LabeledContent("Session timelines", value: timeline.privacySummary)
            LabeledContent("Remember session notices", value: attention.error ?? (attention.saving ? "On" : "Off"))
            Text("Anything left off or unfinished can be managed in Settings later.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var usageStatus: String {
        if !integration.enabled { return integration.usageRemovalNeeded ? "Off; cleanup pending" : "Off" }
        if integration.error != nil { return "Needs attention" }
        if !integration.usageConfigured { return "Approval incomplete" }
        return integration.ready ? "Configured" : "Receiver unavailable"
    }

    private var accountStatus: String {
        if model.accountBusy { return "In progress" }
        if model.accountStale { return "Needs attention" }
        if model.accountSnapshot != nil { return "Connected" }
        return model.accountConnectionEnabled ? "Quota unavailable" : "Not connected"
    }
}
