import AppKit
import Combine
import Foundation
import TokenotchCore
import UniformTypeIdentifiers

@MainActor
final class VSCodeIntegrationController: ObservableObject {
    enum SetupPhase: Equatable {
        case idle, installing, companionReady, startingReceiver, awaitingApproval
        case configured, removed, cancelled, blocked, failed
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var companionInstalled: Bool
    @Published private(set) var activityConfigured: Bool
    @Published private(set) var usageConfigured: Bool
    @Published private(set) var activityRemovalNeeded: Bool
    @Published private(set) var usageRemovalNeeded: Bool
    @Published private(set) var removingActivity: Bool
    @Published var reviewingChoices = false
    @Published var setupIncludesUsage: Bool {
        didSet { defaults.set(setupIncludesUsage, forKey: "vscodeSetupIncludesUsage") }
    }
    @Published private(set) var phase = SetupPhase.idle
    @Published private(set) var pendingRequest: SetupRequest? {
        didSet {
            approvalTimer?.invalidate()
            approvalTimer = nil
            if pendingRequest != nil {
                approvalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            }
        }
    }
    @Published private(set) var status = "VS Code metrics are off"
    @Published private var setupError: String?
    @Published private var receiverError: String?
    var error: String? { setupError ?? receiverError }
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var lastObservation: [UsageSource: Date] = [:]
    @Published private(set) var accepted: [UsageSource: Int] = [:]
    @Published private(set) var rejected = 0
    @Published private(set) var excluded = 0
    @Published private(set) var failedRequests = 0
    @Published private(set) var lastFailedRequestError: String?
    var onBatch: ((TelemetryBatch) -> Void)?
    var onAvailability: ((Bool) -> Void)?
    var onCoverageGap: ((Set<UsageSource>) -> Void)?
    private let defaults: UserDefaults
    private let root: URL
    private let openSetupURL: (URL) -> Bool
    private let receiver = OTLPReceiver()
    private var configuration: TelemetryConfiguration?
    private var pendingSetup = false
    private var requestExpiry = Date.distantPast
    private var approvalTimer: Timer?
    private var installer: Process?
    private var installerGeneration = UUID()
    private var installerDeadline: Task<Void, Never>?
    private var generation = UUID()

    struct SetupRequest: Encodable {
        let version = 1
        let nonce: String
        let expiresAt: Int
        let operation: String
        let hooks: Bool
        let metrics: Bool
        let endpoints: [String: String]?

        init(nonce: String, expiry: Date, operation: String, hooks: Bool, metrics: Bool,
             endpoints: [String: String]?) {
            self.nonce = nonce
            expiresAt = Int(expiry.timeIntervalSince1970)
            self.operation = operation
            self.hooks = hooks
            self.metrics = metrics
            self.endpoints = endpoints
        }
    }

    private struct SetupResult: Decodable {
        let version: Int
        let nonce: String
        let operation: String
        let status: String
    }

    var isWorking: Bool { busy || pendingSetup || pendingRequest != nil }
    private var showsReceiverStatus: Bool { phase == .idle || phase == .configured }

    init(defaults: UserDefaults, root: URL, openSetupURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.root = root
        self.openSetupURL = openSetupURL
        let metricsEnabled = defaults.bool(forKey: "vscodeMetricsEnabled")
        let activityApproved = defaults.bool(forKey: "vscodeActivityConfigured")
        let usageApproved = defaults.bool(forKey: "vscodeUsageConfigured")
        enabled = metricsEnabled
        setupIncludesUsage = metricsEnabled || defaults.bool(forKey: "vscodeSetupIncludesUsage")
        companionInstalled = defaults.bool(forKey: "vscodeCompanionInstalled")
        activityConfigured = activityApproved
        usageConfigured = usageApproved
        activityRemovalNeeded = defaults.bool(forKey: "vscodeActivityRemovalNeeded") || activityApproved
        usageRemovalNeeded = defaults.bool(forKey: "vscodeUsageRemovalNeeded") || usageApproved || metricsEnabled
        removingActivity = defaults.bool(forKey: "vscodeRemovingActivity")
        if defaults.bool(forKey: "vscodeSetupInterrupted") {
            phase = .failed
            status = "The previous setup did not finish. Review your choices and request fresh approval in VS Code."
        } else if removingActivity {
            phase = .blocked
            status = "Activity is disconnected, but VS Code settings still need cleanup. Retry removal in the original editor profile."
        } else if activityApproved {
            phase = .configured
            status = "Activity settings approved. Reload VS Code and send a Copilot prompt to verify delivery."
        } else if companionInstalled {
            phase = .companionReady
            status = "Setup extension installed. Reload your VS Code window, then continue here."
        }
    }

    func start() {
        guard enabled else { return }
        startReceiver()
    }

    func stop() {
        generation = UUID()
        cancelInstaller()
        pendingSetup = false
        pendingRequest = nil
        receiver.stop()
        ready = false
        onAvailability?(false)
    }

    private func cancelInstaller() {
        installerGeneration = UUID()
        installerDeadline?.cancel()
        installerDeadline = nil
        let process = installer
        installer = nil
        busy = false
        process?.terminationHandler = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func clearObservations() {
        lastObservation = [:]
        accepted = [:]
        rejected = 0
        excluded = 0
        failedRequests = 0
        lastFailedRequestError = nil
        clearErrors()
        if showsReceiverStatus {
            status = ready ? "Listening locally; awaiting VS Code usage" : "VS Code usage is not connected"
        }
    }

    func configure(metrics: Bool) {
        guard !isWorking else {
            setupError = "Finish the current setup or cancel its approval in VS Code before starting another."
            return
        }
        clearErrors()
        reviewingChoices = false
        defaults.set(true, forKey: "vscodeSetupInterrupted")
        setupIncludesUsage = metrics
        activityRemovalNeeded = true
        defaults.set(true, forKey: "vscodeActivityRemovalNeeded")
        if metrics {
            usageRemovalNeeded = true
            defaults.set(true, forKey: "vscodeUsageRemovalNeeded")
            enabled = true
            defaults.set(true, forKey: "vscodeMetricsEnabled")
            if ready { writeRequest(operation: "configure", hooks: true, metrics: true) }
            else {
                pendingSetup = true
                phase = .startingReceiver
                status = "Starting the private local usage connection"
                startReceiver()
            }
        } else {
            writeRequest(operation: "configure", hooks: true, metrics: false)
        }
    }

    func remove(hooks: Bool) {
        guard !isWorking else {
            setupError = "Finish the current setup or cancel its approval in VS Code before removing settings."
            return
        }
        clearErrors()
        reviewingChoices = false
        defaults.set(true, forKey: "vscodeSetupInterrupted")
        if hooks {
            removingActivity = true
            defaults.set(true, forKey: "vscodeRemovingActivity")
            activityRemovalNeeded = true
            defaults.set(true, forKey: "vscodeActivityRemovalNeeded")
        }
        usageRemovalNeeded = true
        defaults.set(true, forKey: "vscodeUsageRemovalNeeded")
        stop()
        enabled = false
        setupIncludesUsage = false
        defaults.set(false, forKey: "vscodeMetricsEnabled")
        pendingSetup = false
        writeRequest(operation: "remove", hooks: hooks, metrics: true)
        do {
            let file = root.appendingPathComponent("vscode-telemetry.json")
            if try PrivateFiles.read(file) != nil, unlink(file.path) != 0 { throw TokenotchError.storage }
            configuration = nil
            accepted = [:]
            lastObservation = [:]
        } catch { fail(error) }
    }

    func tick(now: Date = Date()) {
        guard let request = pendingRequest else { return }
        do {
            guard now <= requestExpiry else {
                pendingRequest = nil
                phase = .failed
                setupError = "Approval expired. Review your choices and try again."
                status = "Setup needs a fresh approval in VS Code."
                return
            }
            guard let data = try PrivateFiles.read(root.appendingPathComponent("vscode-setup-result.json"), limit: 16_384) else { return }
            let result = try JSONDecoder().decode(SetupResult.self, from: data)
            guard result.version == 1, result.nonce == request.nonce,
                  result.operation == request.operation else { return }
            pendingRequest = nil
            clearErrors()
            switch result.status {
            case "configured":
                guard request.operation == "configure" else { throw TelemetryError.setup }
                if request.hooks {
                    activityConfigured = true
                    removingActivity = false
                    defaults.set(false, forKey: "vscodeRemovingActivity")
                    defaults.set(true, forKey: "vscodeActivityConfigured")
                }
                if request.metrics {
                    usageConfigured = true
                    defaults.set(true, forKey: "vscodeUsageConfigured")
                }
                phase = .configured
                status = "Settings approved. Reload VS Code, then send a Copilot prompt to verify the connection."
            case "removed":
                guard request.operation == "remove" else { throw TelemetryError.setup }
                if request.hooks {
                    activityConfigured = false
                    removingActivity = false
                    defaults.set(false, forKey: "vscodeRemovingActivity")
                    activityRemovalNeeded = false
                    defaults.set(false, forKey: "vscodeActivityConfigured")
                    defaults.set(false, forKey: "vscodeActivityRemovalNeeded")
                }
                if request.metrics {
                    usageConfigured = false
                    usageRemovalNeeded = false
                    defaults.set(false, forKey: "vscodeUsageConfigured")
                    defaults.set(false, forKey: "vscodeUsageRemovalNeeded")
                }
                phase = .removed
                status = "Tokenotch-owned settings removed. Reload VS Code to finish."
            case "cancelled":
                phase = .cancelled
                status = "Approval cancelled in VS Code. You can resume setup when you are ready."
            case "blocked":
                phase = .blocked
                status = request.operation == "remove"
                    ? "Collection is stopped, but VS Code settings still need cleanup. Review its error dialog, then retry removal."
                    : "VS Code blocked the settings change. Review its error dialog, resolve the conflict, then retry."
            default:
                throw TelemetryError.setup
            }
            defaults.set(false, forKey: "vscodeSetupInterrupted")
        } catch { fail(error) }
    }

    @discardableResult
    func installCompanion() -> Bool {
        guard !isWorking else {
            setupError = "Finish the current setup or cancel its approval in VS Code before updating the extension."
            return false
        }
        let panel = NSOpenPanel()
        panel.title = "Install Tokenotch in Visual Studio Code"
        panel.message = "Select the editor you use, not Tokenotch. The setup extension lets VS Code ask for your approval before Tokenotch changes its settings. Installing it does not start activity or usage collection."
        panel.prompt = "Install extension"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return false }
        guard let application = panel.url,
              let bundle = Bundle(url: application),
              ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains(bundle.bundleIdentifier ?? "") else {
            setupError = "Select Visual Studio Code.app or Visual Studio Code - Insiders.app, not Tokenotch or another application."
            return false
        }
        clearErrors()
        let cli = application.appendingPathComponent("Contents/Resources/app/bin/code")
        let vsix = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TokenotchVSCode.vsix")
        guard FileManager.default.isExecutableFile(atPath: cli.path),
              FileManager.default.fileExists(atPath: vsix.path) else { fail(TelemetryError.setup); return false }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["--install-extension", vsix.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let installID = UUID()
        installerGeneration = installID
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.installerGeneration == installID else { return }
                self.installerDeadline?.cancel()
                self.installerDeadline = nil
                self.installer = nil
                self.busy = false
                if process.terminationStatus == 0 {
                    self.companionInstalled = true
                    self.defaults.set(true, forKey: "vscodeCompanionInstalled")
                    self.defaults.set(bundle.bundleIdentifier == "com.microsoft.VSCodeInsiders" ? "vscode-insiders" : "vscode",
                                      forKey: "vscodeURIScheme")
                    self.phase = .companionReady
                    self.defaults.set(false, forKey: "vscodeSetupInterrupted")
                    self.status = "Setup extension installed. Reload your VS Code window, then continue here."
                } else { self.fail(TelemetryError.setup) }
            }
        }
        do {
            try process.run()
            reviewingChoices = false
            defaults.set(true, forKey: "vscodeSetupInterrupted")
            installer = process
            busy = true
            phase = .installing
            installerDeadline = Task { [weak self, weak process] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
                guard let self, let process, process.isRunning, self.installerGeneration == installID else { return }
                self.cancelInstaller()
                self.fail(TelemetryError.setup)
            }
            return true
        } catch { fail(error); return false }
    }

    private func startReceiver() {
        guard !ready else { return }
        let id = UUID()
        generation = id
        do {
            try PrivateFiles.directory(root)
            let file = root.appendingPathComponent("vscode-telemetry.json")
            let config = try PrivateFiles.read(file).map { try JSONDecoder().decode(TelemetryConfiguration.self, from: $0) }
                ?? TelemetryConfiguration()
            try config.validate()
            configuration = config
            receiver.onReady = { [weak self] ready in
                Task { @MainActor in
                    guard let self, self.generation == id, self.enabled else { return }
                    do {
                        try PrivateFiles.write(try JSONEncoder().encode(ready), to: file)
                        self.configuration = ready
                        self.ready = true
                        self.receiverError = nil
                        if self.showsReceiverStatus { self.status = "Listening locally; awaiting VS Code usage" }
                        self.onAvailability?(true)
                        if self.pendingSetup {
                            self.pendingSetup = false
                            self.writeRequest(operation: "configure", hooks: true, metrics: true)
                        }
                    } catch { self.stop(); self.fail(error) }
                }
            }
            receiver.onFailure = { [weak self] failure in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    if failure != .unavailable {
                        self.failedRequests += 1
                        self.lastFailedRequestError = failure.rawValue
                    }
                    self.fail(failure, setup: self.pendingSetup)
                    self.onCoverageGap?([.vscodeLocal, .vscodeCopilot])
                    if failure == .unavailable { self.ready = false; self.onAvailability?(false) }
                }
            }
            receiver.onBatch = { [weak self] source, batch, completion in
                Task { @MainActor in
                    guard let self, self.generation == id, self.enabled, self.ready else { completion(false); return }
                    self.rejected += batch.rejected
                    self.excluded += batch.filtered
                    self.accepted[source, default: 0] += batch.events.count
                    if !batch.events.isEmpty {
                        self.lastObservation[source] = Date()
                        if self.showsReceiverStatus { self.status = "Receiving local VS Code usage" }
                        if batch.rejected == 0 { self.receiverError = nil }
                    }
                    if batch.rejected > 0 {
                        self.receiverError = TelemetryError.invalid.rawValue
                        self.onCoverageGap?([source])
                    }
                    self.onBatch?(batch)
                    completion(true)
                }
            }
            try receiver.start(config)
        } catch { fail(error) }
    }

    private func writeRequest(operation: String, hooks: Bool, metrics: Bool) {
        do {
            try PrivateFiles.directory(root)
            if metrics && operation == "configure" && !ready { throw TelemetryError.unavailable }
            let nonce = TelemetryConfiguration().token
            let expiry = Date().addingTimeInterval(600)
            let endpoints = configuration.map { config in
                Dictionary(uniqueKeysWithValues: [UsageSource.vscodeLocal, .vscodeCopilot].map { ($0.rawValue, config.endpoint($0)) })
            }
            let request = SetupRequest(nonce: nonce, expiry: expiry,
                                       operation: operation, hooks: hooks, metrics: metrics, endpoints: endpoints)
            try PrivateFiles.write(try JSONEncoder().encode(request), to: root.appendingPathComponent("vscode-setup-request.json"))
            pendingRequest = request
            requestExpiry = Date(timeIntervalSince1970: TimeInterval(request.expiresAt))
            phase = .awaitingApproval
            status = "Approve the Tokenotch settings change in VS Code, then return here."
            openApproval()
        } catch { fail(error) }
    }

    func openApproval() {
        guard let request = pendingRequest else { return }
        let scheme = defaults.string(forKey: "vscodeURIScheme") ?? "vscode"
        guard ["vscode", "vscode-insiders"].contains(scheme),
              let url = URL(string: "\(scheme)://\(TokenotchProduct.companionID)/setup?nonce=\(request.nonce)"),
              openSetupURL(url) else {
            setupError = "Could not open the approval in VS Code. Open your selected editor, then try Open approval again."
            return
        }
        clearErrors()
    }

    private func clearErrors() {
        setupError = nil
        receiverError = nil
    }

    private func fail(_ error: Error, setup: Bool = true) {
        if setup {
            pendingSetup = false
            phase = pendingRequest == nil ? .failed : .awaitingApproval
            status = "Setup could not finish. Review the error, then retry."
        }
        let message = (error as? TelemetryError)?.rawValue ?? (error as? TokenotchError)?.rawValue ?? TelemetryError.setup.rawValue
        if setup { setupError = message }
        else { receiverError = message }
    }
}
