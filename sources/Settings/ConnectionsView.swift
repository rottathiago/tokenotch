import AppKit
import TokenotchCore
import SwiftUI

private final class ConnectionsSelection: ObservableObject {
    @Published var setupClient: Client?
    @Published var removingClient: Client?
    @Published var removingUsage = false
    @Published var claudeSetup = false
    @Published var removingClaude = false
    @Published var enablingClaudeStatusLine = false
    @Published var enablingClaudeSessions = false
}

enum ConnectionReadiness: Equatable {
    case off, cleanupNeeded, needsSetup, waiting, receiving, stale, unavailable

    var title: String {
        switch self {
        case .off: return "Off"
        case .cleanupNeeded: return "Off; cleanup pending"
        case .needsSetup: return "Setup incomplete"
        case .waiting: return "Waiting for data"
        case .receiving: return "Data received"
        case .stale: return "No recent data"
        case .unavailable: return "Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "circle"
        case .cleanupNeeded: return "exclamationmark.circle"
        case .needsSetup: return "circle.dotted"
        case .waiting: return "clock"
        case .receiving: return "checkmark.circle"
        case .stale: return "clock.badge.questionmark"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    static func activity(installed: Bool, approved: Bool, observed: Date?, now: Date) -> Self {
        Self(SignalReadiness(capability: .supported, enabled: installed, configured: approved,
                             listening: installed, observed: observed).delivery(now: now))
    }

    static func usage(enabled: Bool, approved: Bool, ready: Bool, observed: Date?, now: Date) -> Self {
        Self(SignalReadiness(capability: .supported, enabled: enabled, configured: approved,
                             listening: ready, observed: observed).delivery(now: now))
    }

    private init(_ delivery: SignalDelivery) {
        switch delivery {
        case .off: self = .off
        case .needsSetup: self = .needsSetup
        case .waiting: self = .waiting
        case .receiving: self = .receiving
        case .stale: self = .stale
        case .unverified, .unsupported, .unavailable, .rejected: self = .unavailable
        }
    }
}

struct ConnectionCapabilityRow: View {
    let title: String
    let detail: String
    let readiness: ConnectionReadiness

    var body: some View {
        LabeledContent {
            StatusBadge(text: readiness.title, symbol: readiness.symbol, tone: readiness.tone)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

extension ConnectionReadiness {
    var tone: StatusBadge.Tone {
        switch self {
        case .receiving: return .good
        case .cleanupNeeded, .stale, .unavailable: return .caution
        case .off, .needsSetup, .waiting: return .neutral
        }
    }
}

private struct ConnectionHeader: View {
    let client: Client
    let title: String
    let configured: Bool

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconTile(symbol: client.symbol, color: client == .cli ? .gray : .blue, size: 20)
            Text(title)
            Spacer()
            StatusBadge(text: configured ? "Configured" : "Not configured",
                        symbol: configured ? "checkmark.circle" : "circle.dotted",
                        tone: configured ? .good : .neutral)
                .help(configured
                      ? "Setup is complete. Data delivery is shown separately below."
                      : "Complete or repair this client's setup to configure the connection.")
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionsView: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var integration: VSCodeIntegrationController
    @ObservedObject private var claude: ClaudeCodeIntegrationController
    @ObservedObject private var claudeAccount: ClaudeAccountController
    @StateObject private var selection = ConnectionsSelection()

    init(model: TokenotchModel) {
        self.model = model
        integration = model.vscode
        claude = model.claude
        claudeAccount = model.claude.account
    }

    var body: some View {
        Form {
            if model.managedHooksDisabled {
                Section {
                    Label("Client connections are turned off by your organization.", systemImage: "lock.fill")
                        .foregroundStyle(SettingsStyle.caution)
                }
            }
            Section {
                Toggle("Show GitHub Copilot in the notch", isOn: $model.options.showCopilotBadge)
                Toggle("Show Claude Code in the notch", isOn: $model.options.showClaudeNotch)
            } header: {
                Text("Notch providers")
            } footer: {
                SettingsFootnote("Choose which providers appear in the notch. Claude Code appears after setup or when saved usage is available. Hiding a provider does not disconnect it or pause recording. Turn both off to hide the notch.")
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ConnectionCapabilityRow(title: "Activity", detail: "Working, stopped and attention reports",
                        readiness: model.managedHooksDisabled ? .unavailable : .activity(
                            installed: model.registeredClients.contains(.cli), approved: true,
                            observed: model.lastActivityEvent[.cli], now: model.clock))
                    ConnectionCapabilityRow(title: "Model & token usage", detail: "Included with CLI setup",
                        readiness: model.managedHooksDisabled ? .unavailable : .activity(
                            installed: model.registeredClients.contains(.cli), approved: true,
                            observed: model.lastCLIUsageEvent, now: model.clock))
                    if model.isClientConfigured(.cli) && model.lastEvent[.cli] == nil {
                        Text("Start a new Copilot CLI session, or reload its extensions. Tokenotch will show data when the client reports it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if model.isClientConfigured(.cli) {
                            Button("Open Terminal") { model.openClient(.cli) }
                        } else {
                            Button("Set up Copilot CLI...") { selection.setupClient = .cli }
                                .disabled(model.managedHooksDisabled)
                        }
                        Spacer()
                        Menu("Options") {
                            Button("Review or repair setup...") { selection.setupClient = .cli }
                                .disabled(model.managedHooksDisabled)
                            Button("Disconnect...", role: .destructive) { selection.removingClient = .cli }
                                .disabled(!model.registeredClients.contains(.cli))
                        }.fixedSize()
                    }
                    HistoryControls(history: model.history, showsManagement: false)
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub Copilot").font(.caption).foregroundStyle(.secondary)
                    ConnectionHeader(client: .cli, title: "Copilot CLI", configured: model.isClientConfigured(.cli))
                }
            } footer: {
                SettingsFootnote("Configured means setup is complete, even before data arrives. Activity and usage show data delivery separately.")
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ConnectionCapabilityRow(title: "Activity", detail: "Working and stopped sessions",
                        readiness: model.managedHooksDisabled ? .unavailable : .activity(
                            installed: model.registeredClients.contains(.vscode), approved: integration.activityConfigured,
                            observed: model.lastActivityEvent[.vscode], now: model.clock))
                    ConnectionCapabilityRow(title: "Model & token usage", detail: "Optional local collection; no chat content",
                                            readiness: vscodeUsageReadiness)
                    if integration.phase != .idle {
                        Label(integration.status, systemImage: integration.phase == .blocked ? "exclamationmark.triangle" : "info.circle")
                            .font(.callout).foregroundStyle(integration.phase == .blocked ? Color.orange : .secondary)
                    }
                    if let error = integration.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    HStack {
                        Button(vscodeAction) { selection.setupClient = .vscode }
                            .disabled(model.managedHooksDisabled)
                        if integration.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Menu("Options") {
                            Button("Open VS Code") { model.openClient(.vscode) }
                            Button("Update setup extension...") {
                                if integration.installCompanion() { selection.setupClient = .vscode }
                            }.disabled(integration.isWorking || model.managedHooksDisabled)
                            if integration.enabled || integration.usageRemovalNeeded {
                                Button(integration.enabled ? "Turn off model & token usage..." : "Finish removing usage settings...",
                                       role: .destructive) { selection.removingUsage = true }
                                    .disabled(integration.isWorking)
                            }
                            Button("Disconnect...", role: .destructive) { selection.removingClient = .vscode }
                                .disabled(integration.isWorking || (!model.registeredClients.contains(.vscode)
                                    && !integration.activityRemovalNeeded && !integration.enabled && !integration.usageRemovalNeeded))
                        }.fixedSize()
                    }
                }
                DisclosureGroup("Connection details") {
                    Text("Activity uses a small local helper. Usage uses a separate, protected connection on this Mac. The setup extension asks VS Code to configure both; you do not need to edit settings by hand.")
                    ForEach([UsageSource.vscodeLocal, .vscodeCopilot]) { source in
                        LabeledContent(source == .vscodeLocal ? "Chat in VS Code" : "Copilot Agent Host") {
                            if let date = integration.lastObservation[source] {
                                Text(date, style: .relative)
                            } else { Text("No usage received") }
                        }
                    }
                    Text("The companion requires local macOS VS Code 1.138.0 or newer. Hook support is Preview and must be verified with actual delivery. Remote windows, cloud agents and legacy background sessions sharing the CLI exporter are not collected.")
                    if integration.rejected > 0 { Text("\(integration.rejected) unsupported observations; totals are partial.").foregroundStyle(.orange) }
                    if integration.failedRequests > 0 {
                        Text("\(integration.failedRequests) earlier telemetry requests rejected; usage totals may be incomplete.")
                            .foregroundStyle(.orange)
                        if let error = integration.lastFailedRequestError {
                            Text("Last rejected request: \(error)")
                        }
                    }
                    if integration.excluded > 0 { Text("\(integration.excluded) aggregate or excluded observations ignored.") }
                    Text("If setup is blocked, review the error in VS Code or run Tokenotch: Check integration there. Existing collectors, environment overrides and policy are never replaced automatically.")
                }.font(.caption).foregroundStyle(.secondary)
            } header: {
                ConnectionHeader(client: .vscode, title: "Visual Studio Code", configured: model.isClientConfigured(.vscode))
            } footer: {
                SettingsFootnote("Configured confirms activity setup. Model & token usage is optional and has its own data status.")
            }
            Section {
                LabeledContent("CLI model & token usage", value: claude.readiness(.claudeCLI).metrics.delivery(now: model.clock).rawValue)
                LabeledContent("Working activity & notifications", value: "Not verified; unavailable")
                Text(claude.status).font(.caption).foregroundStyle(.secondary)
                if let error = claude.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SettingsStyle.caution)
                }
                HStack {
                    Button(claude.configured ? "Review Claude setup..." : "Set up Claude Code...") {
                        selection.claudeSetup = true
                    }.disabled(claude.isWorking || model.managedHooksDisabled)
                    if claude.busy { ProgressView().controlSize(.small) }
                    if claude.enabled && !claude.ready {
                        Button("Retry receiver") { claude.retry() }.disabled(claude.isWorking || model.managedHooksDisabled)
                    }
                    Spacer()
                    Button("Disconnect...", role: .destructive) { selection.removingClaude = true }
                        .disabled(claude.isWorking || (!claude.enabled && !claude.cleanupNeeded))
                }
                DisclosureGroup("Claude account sign-in") {
                    TextField("Claude CLI executable", text: $claudeAccount.executable)
                        .textFieldStyle(.roundedBorder)
                    Text(claudeAccount.status)
                    HStack {
                        Button("Sign in to Claude...") {
                            claudeAccount.signIn(configurationRoot: claude.configurationRoot)
                        }
                        Button("Check sign-in") {
                            claudeAccount.connect(configurationRoot: claude.configurationRoot)
                        }
                        if claudeAccount.busy { ProgressView().controlSize(.small) }
                        if claudeAccount.enabled {
                            Button("Stop account checks") { claudeAccount.disconnect() }
                        }
                    }.disabled(model.managedAccountDisabled || claudeAccount.busy)
                    Text("Sign-in opens the official Claude CLI in Terminal and your browser. Tokenotch checks only the CLI's authentication status; it never reads stored credentials. Stopping account checks keeps your CLI login.")
                    Text("Sign-in does not enable collection or saving history. Enable quota and context separately below: eligible subscriptions report 5-hour and 7-day usage/reset windows through the CLI status line, not a separate account-quota API. Usage in the Claude app is not collected.")
                }.font(.caption).foregroundStyle(.secondary)
                LabeledContent("CLI quota & session context", value: claude.statusLineEnabled
                    ? (claude.statusLineState.latest == nil ? "Waiting for status-line data" : "Data received")
                    : "Off")
                if let error = claude.statusLineError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SettingsStyle.caution)
                }
                if claude.statusLineEnabled {
                    Button("Turn off quota & context") { claude.disableStatusLine() }
                } else {
                    Button("Enable quota & context...") { selection.enablingClaudeStatusLine = true }
                        .disabled(!claude.ready || claude.isWorking || model.managedHooksDisabled)
                }
                LabeledContent("Session start/end tracking", value: claude.sessionTrackingEnabled ? "Enabled" : "Off")
                if let error = claude.sessionTrackingError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SettingsStyle.caution)
                }
                if claude.sessionTrackingEnabled {
                    Button("Turn off session tracking") { claude.disableSessionTracking() }
                } else {
                    Button("Enable session tracking...") { selection.enablingClaudeSessions = true }
                        .disabled(!claude.ready || claude.isWorking || model.managedHooksDisabled)
                }
                DisclosureGroup("Coverage and privacy") {
                    Text("Experimental Claude Code CLI metrics. Numeric delivery was checked on Claude Code 2.1.212; no minimum supported version is established. Restart CLI sessions after setup. Configuration alone is not proof of delivery.")
                    Text("Only API-request usage is counted. Missing stable request identity is rejected; missing sessions stay unlinked. Tokenotch does not read transcripts, credentials or account profiles.")
                    Text("Quota and context are a separate opt-in using Claude's documented statusLine input. Setup adds a local numeric helper only if no status line already exists. Existing sessions report on their next status-line update; resume or restart if needed. No credentials or transcripts are read.")
                    Text("Claude reports 5-hour and 7-day limits for eligible subscriptions after an API response. Missing fields are not zero usage. Idle readings become stale, and past reset times wait for a new report. Context uses the latest input and cache tokens, not cumulative session usage.")
                    Text("Session tracking is a separate opt-in. Start/end hooks keep observed CLI sessions visible while idle and remove them when they end; they do not detect working activity, completion or attention. Force-quitting Claude or missing hooks can prevent delivery. Restart or resume sessions after enabling.")
                    Text("\(claude.accepted) accepted observations; \(claude.rejected) unsupported; \(claude.unlinked) unlinked; \(claude.failedRequests) rejected requests. Replays are deduplicated by the ledger.")
                    if !claude.rejectionStages.isEmpty {
                        Text("Rejection reasons since Tokenotch started")
                        ForEach(claude.rejectionStages.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { stage in
                            LabeledContent(stage.title, value: (claude.rejectionStages[stage] ?? 0).formatted())
                        }
                        Text("Only fixed reason categories and counts are kept in memory. Rejected field values, raw telemetry and conversation content are not saved.")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                HistoryControls(history: model.history, showsManagement: false, provider: .claudeCode)
            } header: {
                ConnectionHeader(client: .claudeCLI, title: "Claude Code CLI", configured: claude.configured)
            } footer: {
                SettingsFootnote("Account sign-in, collection, session tracking, saving history and notch visibility are independent. Disconnect keeps saved data. Working activity and notifications remain unavailable.")
            }
            Section {
                DisclosureGroup("Troubleshooting") {
                    LabeledContent("Local activity receiver", value: model.bridgeStatus)
                    ForEach(Client.copilotCases) { client in
                        LabeledContent(client == .cli ? "CLI activity" : "VS Code activity",
                                       value: model.connection[client] ?? "Not installed")
                    }
                    Text("The experimental CLI activity snapshot refreshes every 30 seconds when supported; missing updates become unknown after 90 seconds. Hook-only working reports expire after five minutes. Idle sessions and open windows do not count as working.")
                    Text("For troubleshooting only, the VS Code setup extension manages this hook entry while preserving other locations. Workspace settings or enterprise policy can override it.")
                    Text(model.vscodeSetting).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("After setup, verify both a start and a stop. Opening a client does not focus an exact terminal or workspace.")
                }
            }.font(.callout)
        }
        .formStyle(.grouped)
        .onAppear { model.refreshConnectionInstallations() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshConnectionInstallations()
        }
        .sheet(item: $selection.setupClient) { client in ConnectionSetupView(model: model, client: client) }
        .sheet(isPresented: $selection.claudeSetup) { ClaudeSetupView(model: model, integration: claude) }
        .confirmationDialog("Enable Claude quota and context?", isPresented: $selection.enablingClaudeStatusLine, titleVisibility: .visible) {
            Button("Enable quota & context") { model.enableClaudeStatusLine() }
        } message: {
            Text("Add Tokenotch's status line to the selected Claude settings. It displays numeric context and quota in Claude and forwards those fields locally. Existing status lines are never replaced. Claude may hide some built-in keyboard hints while a custom status line is active. No account credentials or transcripts are accessed.")
        }
        .confirmationDialog("Track Claude session starts and ends?", isPresented: $selection.enablingClaudeSessions, titleVisibility: .visible) {
            Button("Enable session tracking") { model.enableClaudeSessionTracking() }
        } message: {
            Text("Add Tokenotch's SessionStart and SessionEnd hooks to the selected Claude settings, preserving other hooks. Only hashed session IDs, start/end state and observation times are forwarded locally, never prompts or transcripts. Usage totals are retained when a session closes. Restart or resume Claude sessions afterward.")
        }
        .confirmationDialog("Disconnect Claude Code?", isPresented: $selection.removingClaude, titleVisibility: .visible) {
            Button("Disconnect Claude Code", role: .destructive) { model.removeClaude() }
        } message: {
            Text("Stop only the Claude receiver and remove unchanged Tokenotch-owned exporter, status-line and session-hook entries. Later user edits and Copilot connections are preserved. Saved history, timelines and your Claude CLI login remain. Restart Claude CLI afterward.")
        }
        .confirmationDialog("Disconnect this client?", isPresented: Binding(
            get: { selection.removingClient != nil }, set: { if !$0 { selection.removingClient = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let client = selection.removingClient { model.uninstall(client) }
                selection.removingClient = nil
            }

        } message: {
            Text("Stop new activity and usage observations. Saved history and timelines remain. Only unchanged Tokenotch-owned files and settings are removed; VS Code asks for approval to restore its settings.")
        }
        .confirmationDialog("Turn off model & token usage?", isPresented: $selection.removingUsage, titleVisibility: .visible) {
            Button("Turn off usage", role: .destructive) { model.disableVSCodeMetrics() }
        } message: {
            Text("Stop the local usage receiver and ask VS Code to remove Tokenotch-owned usage settings. Activity stays connected, and saved history remains.")
        }
    }

    private var vscodeAction: String {
        if integration.pendingRequest?.operation == "remove" { return "Finish removing settings..." }
        if integration.isWorking || integration.phase == .companionReady { return "Continue setup..." }
        if integration.phase == .blocked || integration.phase == .failed || integration.phase == .cancelled {
            return "Review setup..."
        }
        return model.registeredClients.contains(.vscode) || integration.activityConfigured
            ? "Manage connection..." : "Set up VS Code..."
    }

    private var vscodeUsageReadiness: ConnectionReadiness {
        if model.managedHooksDisabled { return .unavailable }
        if !integration.enabled && integration.usageRemovalNeeded { return .cleanupNeeded }
        return .usage(enabled: integration.enabled, approved: integration.usageConfigured, ready: integration.ready,
                      observed: integration.lastObservation.values.max(), now: model.clock)
    }
}

private final class ClaudeSetupSelection: ObservableObject {
    @Published var configurationRoot: String
    @Published var reviewed = false

    init(configurationRoot: URL) {
        self.configurationRoot = configurationRoot.path
    }
}

private struct ClaudeSetupView: View {
    let model: TokenotchModel
    @ObservedObject var integration: ClaudeCodeIntegrationController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            ClaudeSetupContent(model: model, integration: integration, close: { dismiss() })
                .padding(24)
        }.frame(width: 520, height: 650)
    }
}

struct ClaudeSetupContent: View {
    let model: TokenotchModel
    @ObservedObject var integration: ClaudeCodeIntegrationController
    var close: (() -> Void)? = nil
    @StateObject private var selection: ClaudeSetupSelection

    init(model: TokenotchModel, integration: ClaudeCodeIntegrationController, close: (() -> Void)? = nil) {
        self.model = model
        self.integration = integration
        self.close = close
        _selection = StateObject(wrappedValue: ClaudeSetupSelection(configurationRoot: integration.configurationRoot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Claude Code CLI").font(.title2.weight(.semibold))
            Text("Enable CLI metrics using a private, logs-only localhost connection in the selected user settings. Other settings and hooks are preserved. Other Claude clients and remote sessions are not collected.")
            TextField("Local configuration root", text: $selection.configurationRoot)
                .textFieldStyle(.roundedBorder)
                .disabled(integration.isWorking)
            Text("Default: ~/.claude. No account or profile discovery. Setup asks before making settings.json private. Folder permissions and file ownership are never changed; symlinked paths are refused.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I checked Claude /status: no managed telemetry or external collector applies, and this is the local CLI configuration root.", isOn: $selection.reviewed)
            Text("Do not continue if a managed collector, telemetry opt-out, shell override or remote configuration applies. Tokenotch checks visible local policy and its own environment but cannot inspect Claude's effective shell or server-managed policy.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = integration.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SettingsStyle.caution)
            }
            Text(integration.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                if let close { Button("Close", action: close).keyboardShortcut(.cancelAction) }
                Spacer()
                if integration.busy { ProgressView().controlSize(.small) }
                Button("Enable CLI metrics") {
                    model.configureClaude(configurationRoot: URL(fileURLWithPath: selection.configurationRoot, isDirectory: true),
                                          policyReviewed: selection.reviewed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!selection.reviewed || !selection.configurationRoot.hasPrefix("/") || integration.isWorking || model.managedHooksDisabled)
            }
        }
        .sheet(item: Binding(get: { integration.permissionChange },
                             set: { if $0 == nil { integration.cancelPermissionChange() } })) { change in
            ClaudePermissionsView(integration: integration, change: change)
        }
        .onDisappear { integration.cancelPermissionChange() }
    }
}

struct ClaudePermissionsView: View {
    @ObservedObject var integration: ClaudeCodeIntegrationController
    let change: ClaudeCodeInstallation.PermissionChange

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Make Claude settings private?", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text("The selected settings.json has permissions \(change.currentPermissions). Tokenotch needs owner-only access before adding its private local connection.")
            Text("Make only this file readable and writable by you (0600), then continue setup. The permission change does not edit its contents, change ownership, or affect the folder or other files.")
            Text("The file stays private after disconnect. Existing settings and hooks are preserved; conflicting collectors or policy still block setup.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { integration.cancelPermissionChange() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Make private and continue") { integration.approvePermissionChange(change) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480).background(.background)
    }
}

struct ConnectionSetupView: View {
    let model: TokenotchModel
    let client: Client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ConnectionSetupContent(model: model, client: client, close: { dismiss() })
            .padding(24)
            .frame(width: 510, height: 450)
            .background(.background)
    }
}

struct ConnectionSetupContent: View {
    @ObservedObject var model: TokenotchModel
    @ObservedObject private var integration: VSCodeIntegrationController
    let client: Client
    var close: (() -> Void)?
    @StateObject private var selection = ConnectionsSelection()

    init(model: TokenotchModel, client: Client, close: (() -> Void)? = nil) {
        self.model = model
        integration = model.vscode
        self.client = client
        self.close = close
    }

    private var showsChoices: Bool {
        integration.reviewingChoices || integration.phase == .idle
            || (integration.phase == .removed && !integration.activityConfigured)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(client == .cli ? "Set up Copilot CLI"
                  : integration.pendingRequest?.operation == "remove" ? "Remove VS Code settings" : "Set up Visual Studio Code",
                  systemImage: client == .cli ? "terminal" : "laptopcomputer")
                .font(close == nil ? .headline : .title2.bold())
            if close != nil {
                ScrollView { instructions }.defaultScrollAnchor(.top)
                actions
            } else {
                if client == .vscode && showsChoices { usageChoice }
                if client == .cli && !model.installedClients.contains(.cli) {
                    Text(model.registeredClients.contains(.cli)
                         ? "Repair Tokenotch's CLI integration, then reload extensions or restart each CLI session."
                         : "Install Tokenotch's local activity hooks and usage extension. No chat content is saved.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                actions
                instructions
            }
        }
        .confirmationDialog("Turn off model & token usage?", isPresented: $selection.removingUsage, titleVisibility: .visible) {
            Button("Turn off usage", role: .destructive) { model.disableVSCodeMetrics() }
        } message: {
            Text("Stop the local usage receiver and ask VS Code to remove Tokenotch-owned usage settings. Activity stays connected, and saved history remains.")
        }
    }

    private var actions: some View {
        HStack {
            if let close {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Spacer()
            }
            if model.managedHooksDisabled {
                Text("Disabled by managed policy").foregroundStyle(.secondary)
            } else if client == .cli {
                if model.registeredClients.contains(.cli) {
                    Button("Open Terminal") { model.openClient(.cli) }
                    Button("Repair setup") { model.install(.cli) }
                } else {
                    Button("Connect Copilot CLI") { model.install(.cli) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                vscodeAction
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if client == .cli { cliSetup }
            else if showsChoices { choices }
            else { vscodeProgress }
            if let error = integration.error, client == .vscode {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SettingsStyle.caution)
            }
            if let error = model.connectionSetupErrors[client] {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SettingsStyle.caution)
            }
            if client == .vscode && (integration.enabled || integration.usageRemovalNeeded) {
                Button(integration.enabled ? "Turn off model & token usage..." : "Finish removing usage settings...") {
                    selection.removingUsage = true
                }.disabled(integration.isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cliSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.installedClients.contains(.cli) {
                Label("Copilot CLI configured", systemImage: "checkmark.circle").font(.headline)
                Text("Start a new Copilot CLI session, or reload extensions in an existing one. Send a prompt and let it finish to verify working and stopped activity.")
                Text("Model and token details appear only when the CLI reports them. Installation alone does not verify delivery.")
                    .foregroundStyle(.secondary)
            } else {
                Text("See working and stopped sessions, model and token usage, and context details when the CLI reports them.")
                Label("Adds Tokenotch's activity hooks and session extension", systemImage: "puzzlepiece.extension")
                Text("The helper delivers events to Tokenotch on this Mac. The session extension reports usage and refreshes live activity, so Tokenotch does not have to read your conversations.")
                Text("No prompts or transcripts are retained. History and timelines are separate opt-ins. This does not sign you into GitHub or change account quotas.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("After connecting, restart your CLI session or reload its extensions to activate the integration.")
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose what Tokenotch can observe. Both capabilities belong to this one VS Code connection.")
            Label("Activity is included", systemImage: "checkmark.circle").font(.headline)
            Text("Show when local Copilot sessions work and stop. A small helper reports these events without retaining your chat.")
                .font(.callout).foregroundStyle(.secondary)
            if close != nil { usageChoice }
            Divider()
            Text(integration.companionInstalled
                 ? "Next, VS Code will ask you to approve the settings change in the selected editor and profile."
                 : "Next, choose your VS Code app to install Tokenotch's setup extension. It lets VS Code ask for your approval before settings are changed.")
            Text("No telemetry is forwarded externally. Only numeric usage, model IDs and hashed identifiers are retained. History requires separate consent; this does not change account quotas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var usageChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include model & token usage", isOn: $integration.setupIncludesUsage)
                .disabled(integration.enabled || integration.isWorking || model.managedHooksDisabled)
            Text(integration.enabled
                 ? "Already requested for this connection. You can turn it off below."
                 : "Optional, off by default. Show model calls and tokens through a protected receiver on this Mac; chat content capture stays off.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var vscodeProgress: some View {
        switch integration.phase {
        case .installing:
            ProgressView("Installing the setup extension...")
            Text("This gives VS Code a way to request your approval. Collection has not been enabled by this installation.")
        case .companionReady:
            Label("Setup extension installed", systemImage: "checkmark.circle").font(.headline)
            Text("In VS Code, run Developer: Reload Window from the Command Palette so the installed extension is active.")
            Text("Then continue below. VS Code will show the exact features you selected and ask permission to change your profile settings.")
        case .startingReceiver:
            ProgressView("Preparing the local usage connection...")
            Text("The receiver accepts only authenticated telemetry on this Mac. Content capture stays off.")
        case .awaitingApproval:
            Label("Approval needed in VS Code", systemImage: "arrow.up.forward.app").font(.headline)
            Text("Switch to your local VS Code window and approve the Tokenotch request. Return here when you are done.")
            Text("The approval belongs to that editor profile. Tokenotch preserves unrelated settings and will not replace an existing collector.")
                .foregroundStyle(.secondary)
        case .configured:
            Label("Settings approved", systemImage: "checkmark.circle").font(.headline)
            Text("Reload VS Code once more to activate the settings. Send a Copilot prompt and let it finish.")
            Text("Activity will appear when events arrive. If usage is enabled, each completed model call can add model and token details. Configuration is complete; data delivery has not necessarily been verified.")
            if integration.setupIncludesUsage {
                Text("Use each session target you intend to monitor. Chat in VS Code and Copilot Agent Host report usage separately.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .blocked, .failed, .cancelled:
            Label(integration.phase == .cancelled ? "Setup paused" : "Setup needs attention",
                  systemImage: "exclamationmark.triangle").font(.headline)
            Text(integration.status)
            Text("For conflicts, review the error or run Tokenotch: Check integration in VS Code. Keep intentional or managed collectors intact. You can connect activity without enabling usage.")
            if integration.setupIncludesUsage && !integration.usageConfigured {
                Text("A usage attempt may have left reversible settings. Turn off usage below before retrying activity-only setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .idle, .removed:
            Text(integration.status)
        }
    }

    @ViewBuilder private var vscodeAction: some View {
        if showsChoices {
            Button(integration.companionInstalled ? "Continue in VS Code" : "Install setup extension...") {
                if integration.companionInstalled {
                    model.configureVSCode(metrics: integration.setupIncludesUsage)
                } else { integration.installCompanion() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(integration.isWorking)
        } else {
            switch integration.phase {
            case .companionReady:
                Button("I've reloaded; continue") { model.configureVSCode(metrics: integration.setupIncludesUsage) }
                Button("Review choices") { integration.reviewingChoices = true }
            case .awaitingApproval:
                Button("Open approval") { integration.openApproval() }
            case .configured:
                Button("Open VS Code") { model.openClient(.vscode) }
                Button("Review choices") { integration.reviewingChoices = true }
            case .blocked, .failed, .cancelled, .idle, .removed:
                Button("Review choices") { integration.reviewingChoices = true }
                if integration.removingActivity {
                    Button("Retry removal") { model.uninstall(.vscode) }
                }
            case .installing, .startingReceiver:
                EmptyView()
            }
        }
    }
}
