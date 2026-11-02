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
            Label("Connect Copilot CLI, Visual Studio Code or experimental Claude Code CLI metrics.", systemImage: "point.3.connected.trianglepath.dotted")
            Label("Prompts, responses and code are not saved.", systemImage: "lock.shield")
            Label("Notifications, saved history and account sign-in are your choice.", systemImage: "slider.horizontal.3")
            Text("We'll configure at least one client together. You can pause and come back to the same step.")
            Text("Move Tokenotch to Applications before connecting. Tokenotch sends no analytics. Daily update checks are off until you enable them in About. A stopped turn is not proof a task succeeded; local token observations are not your bill.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a client to set up. One configured client is enough; other clients can be added later.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(OnboardingProgress.supportedClients) { client in
                    Button { model.selectOnboardingClient(client) } label: {
                        HStack {
                            Label(client == .vscode ? "Visual Studio Code" : client.title, systemImage: client.symbol)
                            if model.onboarding.activeClient == client {
                                Image(systemName: "checkmark").accessibilityHidden(true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
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
                if client.provider == .claudeCode {
                    ClaudeSetupContent(model: model, integration: model.claude).id(client)
                } else { ConnectionSetupContent(model: model, client: client).id(client) }
                Text("Successful configuration lets you continue. Reload the client as instructed; activity can be verified later.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Select a client above to see its setup and privacy choices.")
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
    @ObservedObject private var claude: ClaudeCodeIntegrationController
    let client: Client

    init(model: TokenotchModel, client: Client) {
        self.model = model
        integration = model.vscode
        claude = model.claude
        self.client = client
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(client == .vscode ? "Visual Studio Code" : client.title) {
                StatusBadge(text: model.isClientConfigured(client) ? "Configured" : "Not configured",
                            symbol: model.isClientConfigured(client) ? "checkmark.circle" : "circle.dotted",
                            tone: model.isClientConfigured(client) ? .good : .neutral)
            }
            if client.provider == .claudeCode {
                Text(claude.readiness(.claudeCLI).metrics.delivery(now: model.clock).rawValue)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Metrics only; lifecycle and attention are unavailable. CLI quota and context require a separate opt-in.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.isClientConfigured(client) {
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
            ForEach(UsageProvider.allCases) { provider in
                Text(provider.title).font(.headline)
                HistoryControls(history: model.history, showsManagement: false, provider: provider)
                TimelineRecordingControls(timeline: model.timeline, provider: provider)
            }
            Text("Copilot session notices").font(.headline)
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
            ForEach(OnboardingProgress.supportedClients) { client in
                OnboardingConnectionStatus(model: model, client: client)
            }
            Text("Restart your configured client and use it normally. Claude reports metrics only; Copilot activity has separate delivery evidence. Configured does not mean data has arrived.")
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
            LabeledContent("Claude usage history", value: history.isEnabled(.claudeCode) ? "On" : "Off")
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
