import AppKit
import TokenotchCore
import SwiftUI

private final class ConnectionsSelection: ObservableObject {
    @Published var setupClient: Client?
    @Published var removingClient: Client?
    @Published var removingUsage = false
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
        guard installed else { return .off }
        if let observed { return now.timeIntervalSince(observed) <= 300 ? .receiving : .stale }
        return approved ? .waiting : .needsSetup
    }

    static func usage(enabled: Bool, approved: Bool, ready: Bool, observed: Date?, now: Date) -> Self {
        guard enabled else { return .off }
        if ready, let observed { return now.timeIntervalSince(observed) <= 300 ? .receiving : .stale }
        guard approved else { return .needsSetup }
        guard ready else { return .unavailable }
        return .waiting
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
    @StateObject private var selection = ConnectionsSelection()

    init(model: TokenotchModel) {
        self.model = model
        integration = model.vscode
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
                }
            } header: {
                ConnectionHeader(client: .cli, title: "Copilot CLI", configured: model.isClientConfigured(.cli))
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
                DisclosureGroup("Troubleshooting") {
                    LabeledContent("Local activity receiver", value: model.bridgeStatus)
                    ForEach(Client.allCases) { client in
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
