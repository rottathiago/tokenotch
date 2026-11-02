import Combine
import Foundation
import TokenotchCore

@MainActor
final class ClaudeCodeIntegrationController: ObservableObject {
    let account: ClaudeAccountController
    @Published private(set) var enabled: Bool
    @Published private(set) var configured = false
    @Published private(set) var configurationRoot = ClaudeCodeInstallation.defaultConfigurationRoot
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var permissionChange: ClaudeCodeInstallation.PermissionChange?
    @Published private(set) var cleanupNeeded = false
    @Published private(set) var status = "Claude Code metrics are off"
    @Published private(set) var error: String?
    @Published private(set) var lastObservation: [UsageSource: Date] = [:]
    @Published private(set) var lastRejectedObservation: [UsageSource: Date] = [:]
    @Published private(set) var accepted = 0
    @Published private(set) var rejected = 0
    @Published private(set) var rejectionStages: [ClaudeCodeRejectionStage: Int] = [:]
    @Published private(set) var excluded = 0
    @Published private(set) var unlinked = 0
    @Published private(set) var failedRequests = 0
    @Published private(set) var statusLineEnabled = false
    @Published private(set) var statusLineState = ClaudeStatusLineState()
    @Published private(set) var statusLineError: String?
    @Published private(set) var sessionTrackingEnabled = false
    @Published private(set) var sessionState = ClaudeSessionState()
    @Published private(set) var sessionTrackingError: String?
    var onStatusLine: (() -> Void)?
    var onSessionChange: (() -> Void)?
    var onBatch: ((TelemetryBatch) -> Void)?
    var onAvailability: (() -> Void)?
    var onCoverageGap: ((Set<UsageSource>) -> Void)?
    private let defaults: UserDefaults
    private let installation: ClaudeCodeInstallation
    private let receiver = OTLPReceiver(provider: .claudeCode)
    private let environment: () -> [String: String]
    private let managedPolicyPresent: () -> Bool
    private var generation = UUID()
    private var setup: (root: URL, reviewed: Bool)?
    var isWorking: Bool { busy || permissionChange != nil }
    var collectingSources: Set<UsageSource> {
        guard enabled, ready else { return [] }
        return [.claudeCLI]
    }

    init(defaults: UserDefaults, root: URL,
         environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         managedPolicyPresent: @escaping () -> Bool = { ClaudeCodeInstallation.hasLocalManagedPolicy() }) {
        self.defaults = defaults
        account = ClaudeAccountController(defaults: defaults, root: root)
        installation = ClaudeCodeInstallation(root: root)
        self.environment = environment
        self.managedPolicyPresent = {
            managedPolicyPresent() || (defaults.objectIsForced(forKey: "DisableHooks") && defaults.bool(forKey: "DisableHooks"))
        }
        enabled = defaults.bool(forKey: "claudeMetricsEnabled")
        defaults.removeObject(forKey: "claudeDesktopMetricsEnabled")
    }

    func start() {
        guard !isWorking, !ready else { return }
        do {
            var receipt = try installation.receipt()
            if let receipt { configurationRoot = receipt.configurationRoot }
            cleanupNeeded = receipt != nil
            guard enabled else {
                if receipt != nil { status = "Collection is off; owned settings need cleanup." }
                return
            }
            guard !managedPolicyPresent() else { throw ClaudeSetupError.policy }
            if let saved = receipt, saved.localAttribution == true, saved.owned["OTEL_RESOURCE_ATTRIBUTES"] != nil {
                try installation.install(configurationRoot: saved.configurationRoot, configuration: saved.configuration,
                    policyReviewed: true, environment: environment(), managedPolicyPresent: managedPolicyPresent())
                receipt = try installation.receipt()
            }
            guard let receipt else { throw ClaudeSetupError.interrupted }
            try installation.verify(receipt)
            statusLineEnabled = receipt.statusLineCommand != nil
            sessionTrackingEnabled = receipt.sessionHooks != nil
            configured = true
            listen(receipt.configuration)
        } catch { fail(error) }
    }

    func configure(configurationRoot: URL, policyReviewed: Bool) {
        guard !isWorking else {
            error = "Finish or cancel the current Claude setup before starting another."
            return
        }
        do {
            guard policyReviewed else { throw ClaudeSetupError.review }
            guard !managedPolicyPresent() else { throw ClaudeSetupError.policy }
            try ClaudeCodeInstallation.validateEnvironment(environment())
            let saved = try installation.receipt()
            if let saved, saved.configurationRoot.standardizedFileURL != configurationRoot.standardizedFileURL {
                throw ClaudeSetupError.ownership
            }
            stop()
            self.configurationRoot = configurationRoot
            configured = false
            error = nil
            if let change = try installation.permissionChange(configurationRoot: configurationRoot) {
                permissionChange = change
                status = "Approve making the selected Claude settings.json private to continue setup."
                return
            }
            enabled = true
            defaults.set(true, forKey: "claudeMetricsEnabled")
            setup = (configurationRoot, policyReviewed)
            listen(saved?.configuration ?? TelemetryConfiguration())
        } catch { fail(error) }
    }

    func approvePermissionChange(_ change: ClaudeCodeInstallation.PermissionChange) {
        guard permissionChange == change else {
            error = ClaudeSetupError.changed.rawValue
            return
        }
        do {
            guard !managedPolicyPresent() else { throw ClaudeSetupError.policy }
            try ClaudeCodeInstallation.validateEnvironment(environment())
            try installation.makeSettingsPrivate(change)
            permissionChange = nil
            configure(configurationRoot: change.configurationRoot, policyReviewed: true)
        } catch { fail(error) }
    }

    func cancelPermissionChange() {
        guard permissionChange != nil else { return }
        permissionChange = nil
        status = "Setup cancelled. No Claude file permissions or settings were changed."
    }

    func retry() { stop(); start() }

    func tick() {
        guard enabled, ready else { return }
        do {
            guard !managedPolicyPresent() else { throw ClaudeSetupError.policy }
            guard let receipt = try installation.receipt() else { throw ClaudeSetupError.ownership }
            try installation.verify(receipt)
            statusLineState.expire(now: Date())
            sessionState.expire(now: Date())
        } catch { fail(error) }
    }

    func stop() {
        generation = UUID()
        setup = nil
        permissionChange = nil
        receiver.stop()
        ready = false
        busy = false
        onAvailability?()
    }

    func remove() {
        enabled = false
        defaults.set(false, forKey: "claudeMetricsEnabled")
        stop()
        configured = false
        statusLineEnabled = false
        statusLineState = ClaudeStatusLineState()
        statusLineError = nil
        sessionTrackingEnabled = false
        sessionState = ClaudeSessionState()
        sessionTrackingError = nil
        onStatusLine?()
        onSessionChange?()
        do {
            let complete = try installation.remove()
            cleanupNeeded = !complete
            error = complete ? nil : "User-edited Claude settings were preserved. Review the remaining owned entries before retrying cleanup."
            status = complete ? "Tokenotch-owned Claude settings removed. Restart Claude Code to finish."
                : "Collection is off; cleanup needs review."
        } catch { fail(error) }
        onAvailability?()
    }

    func clearObservations() {
        accepted = 0; rejected = 0; excluded = 0; unlinked = 0; failedRequests = 0
        rejectionStages = [:]
        lastObservation = [:]
        lastRejectedObservation = [:]
        statusLineState = ClaudeStatusLineState()
        sessionState = ClaudeSessionState()
        onStatusLine?()
        onSessionChange?()
    }

    func enableSessionTracking(bundledHelper: URL) {
        guard enabled, ready, !isWorking else { return }
        do {
            guard !managedPolicyPresent() else { throw ClaudeSetupError.policy }
            try ClaudeCodeInstallation.validateEnvironment(environment())
            try installation.enableSessionTracking(bundledHelper: bundledHelper)
            sessionTrackingEnabled = true
            sessionTrackingError = nil
            onSessionChange?()
        } catch {
            sessionTrackingError = (error as? ClaudeSetupError)?.rawValue ?? ClaudeSetupError.storage.rawValue
        }
    }

    func disableSessionTracking() {
        sessionTrackingEnabled = false
        sessionState.stopTracking()
        onSessionChange?()
        do {
            try installation.disableSessionTracking()
            sessionTrackingError = nil
        } catch {
            sessionTrackingError = (error as? ClaudeSetupError)?.rawValue ?? ClaudeSetupError.storage.rawValue
        }
    }

    func receiveSession(_ event: ClaudeSessionEvent, now: Date = Date()) {
        guard enabled, ready, sessionTrackingEnabled else { return }
        do {
            try sessionState.observe(event, now: now)
            sessionTrackingError = nil
            onSessionChange?()
        } catch {
            sessionTrackingError = "A Claude session update was rejected. Session visibility may be incomplete."
        }
    }

    func enableStatusLine(bundledHelper: URL) {
        guard enabled, ready, !isWorking else { return }
        do {
            guard !managedPolicyPresent() else { throw ClaudeSetupError.policy }
            try ClaudeCodeInstallation.validateEnvironment(environment())
            try installation.enableStatusLine(bundledHelper: bundledHelper)
            statusLineEnabled = true
            statusLineError = nil
            onStatusLine?()
        } catch {
            statusLineError = (error as? ClaudeSetupError)?.rawValue ?? ClaudeSetupError.storage.rawValue
        }
    }

    func disableStatusLine() {
        statusLineEnabled = false
        statusLineState = ClaudeStatusLineState()
        onStatusLine?()
        do {
            try installation.disableStatusLine()
            statusLineError = nil
        } catch {
            statusLineError = (error as? ClaudeSetupError)?.rawValue ?? ClaudeSetupError.storage.rawValue
        }
    }

    func receiveStatusLine(_ snapshot: ClaudeStatusLineSnapshot, now: Date = Date()) {
        guard enabled, ready, statusLineEnabled else { return }
        do {
            try statusLineState.observe(snapshot, now: now)
            statusLineError = nil
            onStatusLine?()
        } catch { statusLineError = "A Claude status-line reading was rejected. Quota and context coverage may be incomplete." }
    }

    func readiness(_ source: UsageSource) -> SourceSignalReadiness {
        SourceSignalReadiness(source: source,
            metrics: SignalReadiness(capability: source == .claudeCLI ? .supported : .unsupported,
                enabled: enabled, configured: configured, listening: ready,
                observed: lastObservation[source], rejectedAt: lastRejectedObservation[source]),
            lifecycle: SignalReadiness(capability: .unverified))
    }

    private func listen(_ configuration: TelemetryConfiguration) {
        let id = UUID()
        generation = id
        busy = true
        error = nil
        status = "Starting the private Claude usage connection"
        receiver.onReady = { [weak self] configuration in
            Task { @MainActor in
                guard let self, self.generation == id, self.enabled else { return }
                do {
                    if let setup = self.setup {
                        try self.installation.install(configurationRoot: setup.root, configuration: configuration,
                            policyReviewed: setup.reviewed, environment: self.environment(),
                            managedPolicyPresent: self.managedPolicyPresent())
                        self.setup = nil
                    }
                    guard let saved = try self.installation.receipt() else { throw ClaudeSetupError.interrupted }
                    try self.installation.verify(saved)
                    self.configured = true
                    self.statusLineEnabled = saved.statusLineCommand != nil
                    self.sessionTrackingEnabled = saved.sessionHooks != nil
                    self.cleanupNeeded = true
                    self.ready = true
                    self.busy = false
                    self.error = nil
                    self.status = "Configured. Restart Claude Code CLI, then use an ordinary prompt to verify delivery."
                    self.onAvailability?()
                } catch { self.fail(error) }
            }
        }
        receiver.onBatch = { [weak self] source, batch, completion in
            Task { @MainActor in
                guard let self, self.generation == id, self.enabled, self.ready else { completion(false); return }
                guard source == .claudeCLI else {
                    self.rejected += max(1, batch.events.count + batch.rejected)
                    self.excluded += batch.filtered
                    self.lastRejectedObservation[source] = Date()
                    completion(false)
                    return
                }
                var admitted = batch
                admitted.events.removeAll { !self.collectingSources.contains($0.usageSource) }
                admitted.rejected += batch.events.count - admitted.events.count
                self.accepted += admitted.events.count
                self.rejected += admitted.rejected
                self.excluded += batch.filtered
                self.unlinked += batch.unlinked
                if !admitted.events.isEmpty {
                    for observed in Set(admitted.events.map(\.usageSource)) {
                        self.lastObservation[observed] = Date()
                    }
                    self.status = "Receiving Claude Code CLI usage"
                    if batch.rejected == 0 { self.error = nil }
                }
                if admitted.rejected > 0 {
                    for (stage, count) in admitted.claudeRejections {
                        self.rejectionStages[stage, default: 0] += count
                    }
                    for affected in self.collectingSources { self.lastRejectedObservation[affected] = Date() }
                    let reason = admitted.claudeRejections.keys.sorted {
                        let left = admitted.claudeRejections[$0] ?? 0
                        let right = admitted.claudeRejections[$1] ?? 0
                        return left == right ? $0.rawValue < $1.rawValue : left > right
                    }.first
                    self.error = reason?.explanation ?? "Some Claude observations are unsupported; usage coverage is partial."
                    self.onCoverageGap?(self.collectingSources)
                }
                self.onBatch?(admitted)
                completion(true)
            }
        }
        receiver.onFailure = { [weak self] failure in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.onCoverageGap?(self.collectingSources)
                if failure == .unavailable { self.fail(ClaudeSetupError.unavailable) }
                else {
                    self.failedRequests += 1
                    for source in self.collectingSources { self.lastRejectedObservation[source] = Date() }
                    self.error = "A Claude telemetry request was rejected; usage coverage is partial."
                }
            }
        }
        do { try receiver.start(configuration) }
        catch { fail(ClaudeSetupError.unavailable) }
    }

    private func fail(_ failure: Error) {
        onCoverageGap?(collectingSources)
        stop()
        configured = false
        statusLineEnabled = false
        statusLineState = ClaudeStatusLineState()
        onStatusLine?()
        error = (failure as? ClaudeSetupError)?.rawValue
            ?? (failure as? TokenotchError)?.rawValue ?? ClaudeSetupError.storage.rawValue
        do { cleanupNeeded = try installation.receipt() != nil }
        catch {
            cleanupNeeded = true
            self.error = ClaudeSetupError.storage.rawValue
        }
        status = "Claude collection stopped. Review setup or retry; saved history is retained."
    }
}
