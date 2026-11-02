import AppKit
import Foundation
import SwiftUI
import Vision
import TokenotchCore
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

private final class ClaudeAccountDefaults: UserDefaults, @unchecked Sendable {
    var forceAccount = false
    override func objectIsForced(forKey key: String) -> Bool {
        key == "DisableAccountConnection" && forceAccount
    }
}

@MainActor
enum ClaudeCodeIntegrationChecks {
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try NotchChecks.require(condition(), message)
    }

    private static func send(_ body: Data, config: TelemetryConfiguration, source: UsageSource) async throws -> Int? {
        let signal = source.provider == .copilot ? "traces" : "logs"
        var request = URLRequest(url: URL(string: config.endpoint(source) + "/v1/\(signal)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    }

    static func statusLine() async throws {
        let domain = "tokenotch-claude-statusline-app-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent(domain)
        try PrivateFiles.directory(root)
        let appRoot = root.appendingPathComponent("app")
        let defaults = UserDefaults(suiteName: domain)!
        let controller = ClaudeCodeIntegrationController(defaults: defaults, root: appRoot,
            environment: { [:] }, managedPolicyPresent: { false })
        let model = TokenotchModel(defaults: defaults, root: appRoot, claudeIntegration: controller)
        let bridge = LocalBridge(root: appRoot)
        defer {
            bridge.stop()
            controller.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        controller.configure(configurationRoot: root.appendingPathComponent("client"), policyReviewed: true)
        try await wait("Status-line fixture metrics did not become ready") { controller.ready || controller.error != nil }
        try NotchChecks.require(controller.ready, "Status-line metrics setup failed")
        let now = Date()
        let snapshot = try ClaudeStatusLineSnapshot.parse(ClaudeCodeChecks.statusLineFixture(at: now), now: now)
        controller.receiveStatusLine(snapshot)
        try NotchChecks.require(controller.statusLineState.latest == nil, "Metrics consent enabled status-line collection")
        controller.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        try NotchChecks.require(controller.statusLineEnabled && controller.statusLineError == nil, "Status-line opt-in failed")
        bridge.onClaudeStatusLine = { reading in
            Task { @MainActor in controller.receiveStatusLine(reading) }
        }
        try bridge.start()
        model.history.selectedProvider = .claudeCode
        controller.onBatch?(try ClaudeCodeOTelNormalizer.decode(ClaudeCodeChecks.fixture(at: now), now: now))
        try LocalBridge.send(snapshot, root: appRoot)
        try await wait("Private bridge did not deliver Claude quota/context") { controller.statusLineState.latest != nil }
        try NotchChecks.require(model.sessionMetrics.count == 1 && model.tokenTotals?.total == 170 &&
            model.sessionMetrics[0].context?.usage.currentTokens == 40_000 &&
            model.insights.isEmpty, "Status line changed token accounting or Copilot insights")
        let data = NotchPresentation(model: model, provider: .claudeCode)
        guard let row = data.sessionRows.first else { throw NotchCheckFailure.failed("No Claude context session row") }
        let target = model.currentTarget(row.target)
        try NotchChecks.require(data.claudeStatusLine?.quotas.count == 2 && target.liveHash == snapshot.session &&
            data.context(for: target)?.usage.currentTokens == 40_000 &&
            model.sessionContext(source: .claudeCLI, hash: target.liveHash)?.usage.fraction == 0.2 &&
            data.working.isEmpty && !data.needsAttention, "Claude session context or quota is not linked to its details")
        let content = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
            .frame(width: 310).padding(20).background(.black)
        let image = try NotchChecks.hostedImage(content, size: NSHostingView(rootView: content).fittingSize)
        guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Claude status-line card did not render") }
        let text = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: cgImage).perform([text])
        let visible = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        try NotchChecks.require(visible.contains("5-hour") && visible.contains("7-day") &&
            visible.contains("resets") && visible.contains("context") && visible.contains("20%"),
            "Claude card did not visibly render both quota/reset windows and per-session context: \(visible)")
        let settings = root.appendingPathComponent("client/settings.json")
        let installedSettings = try PrivateFiles.read(settings)
        controller.stop()
        let restarted = ClaudeCodeIntegrationController(defaults: defaults, root: appRoot,
            environment: { [:] }, managedPolicyPresent: { false })
        defer { restarted.stop() }
        restarted.start()
        try await wait("Status-line consent did not survive restart") { restarted.ready || restarted.error != nil }
        let restartedSettings = try PrivateFiles.read(settings)
        try NotchChecks.require(restarted.ready && restarted.statusLineEnabled &&
            restarted.statusLineState.latest == nil && restartedSettings == installedSettings,
            "Restart lost status-line ownership, fabricated readings or rewrote settings")
        restarted.stop()
        controller.start()
        try await wait("Original receiver did not recover after the restart check") { controller.ready || controller.error != nil }
        try NotchChecks.require(controller.ready, "Status-line receiver restart failed")
        model.history.selectedProvider = .copilot
        try NotchChecks.require(model.sessionMetrics.isEmpty &&
            NotchPresentation(model: model, provider: .copilot).sessionRows.isEmpty,
            "Claude context leaked into Copilot's UI")
        model.history.selectedProvider = .claudeCode
        let invalidated = try ClaudeStatusLineSnapshot.parse(
            ClaudeCodeChecks.statusLineFixture(at: now, context: false, quotas: false), now: now.addingTimeInterval(1))
        try LocalBridge.send(invalidated, root: appRoot)
        try await wait("Compaction did not invalidate Claude context") {
            controller.statusLineState.latest?.observedAt == invalidated.observedAt
        }
        try NotchChecks.require(model.sessionMetrics[0].context == nil && controller.statusLineState.latest?.quotas.isEmpty == true,
            "Missing context/quota was presented as zero or retained as current")
        controller.disableStatusLine()
        try NotchChecks.require(!controller.statusLineEnabled && controller.statusLineState.latest == nil &&
            controller.ready && model.tokenTotals?.total == 170, "Turning off quota/context stopped numeric usage")
        try ClaudeCodeChecks.rejects { try LocalBridge.send(snapshot, root: appRoot) }
        controller.remove()
    }

    static func permissionApproval(directory: URL? = nil) async throws {
        let domain = "tokenotch-claude-permission-approval-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(domain)
        try PrivateFiles.directory(root)
        let client = root.appendingPathComponent("client")
        try PrivateFiles.directory(client)
        let settings = client.appendingPathComponent("settings.json")
        let original = Data("{\"theme\":\"dark\",\"hooks\":{\"Stop\":[]}}".utf8)
        try PrivateFiles.write(original, to: settings)
        guard chmod(settings.path, 0o644) == 0 else { throw NotchCheckFailure.failed("Prepare permission fixture") }
        let defaults = UserDefaults(suiteName: domain)!
        var managed = false
        var environment: [String: String] = [:]
        let controller = ClaudeCodeIntegrationController(defaults: defaults, root: root.appendingPathComponent("app"),
            environment: { environment }, managedPolicyPresent: { managed })
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        func mode() throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as! NSNumber).intValue
        }
        controller.configure(configurationRoot: client, policyReviewed: true)
        guard let initial = controller.permissionChange else { throw NotchCheckFailure.failed("Missing permission popup request") }
        let initialMode = try mode()
        try NotchChecks.require(!controller.enabled && !controller.ready && !controller.busy && controller.isWorking &&
            initialMode == 0o644 && !defaults.bool(forKey: "claudeMetricsEnabled"), "Permission review enabled collection or changed the file")
        let content = ClaudePermissionsView(integration: controller, change: initial)
        let image = try NotchChecks.hostedImage(content, size: NSHostingView(rootView: content).fittingSize)
        try NotchChecks.save(image, name: "claude-permission-approval", directory: directory)
        guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Permission popup render unavailable") }
        let text = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: cgImage).perform([text])
        let visibleText = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        try NotchChecks.require(visibleText.contains("make claude settings private") &&
            visibleText.contains("make private and continue") && visibleText.contains("cancel"),
            "The setup permission popup must show readable approval and cancellation actions")
        controller.cancelPermissionChange()
        let cancelledMode = try mode()
        let cancelledContent = try Data(contentsOf: settings)
        try NotchChecks.require(controller.permissionChange == nil && !controller.isWorking &&
            cancelledMode == 0o644 && cancelledContent == original, "Cancelling changed the user's settings")
        controller.configure(configurationRoot: client, policyReviewed: true)
        let policyRequest = controller.permissionChange!
        managed = true
        controller.approvePermissionChange(policyRequest)
        let policyMode = try mode()
        try NotchChecks.require(policyMode == 0o644 && controller.error == ClaudeSetupError.policy.rawValue,
                               "Policy introduced during approval did not block permission changes")
        managed = false
        controller.configure(configurationRoot: client, policyReviewed: true)
        let environmentRequest = controller.permissionChange!
        environment = ["OTEL_LOGS_EXPORTER": "console"]
        controller.approvePermissionChange(environmentRequest)
        let environmentMode = try mode()
        try NotchChecks.require(environmentMode == 0o644 && controller.error == ClaudeSetupError.conflict.rawValue,
                               "An environment conflict introduced during approval was ignored")
        environment = [:]
        controller.configure(configurationRoot: client, policyReviewed: true)
        let stale = controller.permissionChange!
        try original.write(to: settings, options: .atomic)
        guard chmod(settings.path, 0o644) == 0 else { throw NotchCheckFailure.failed("Prepare replacement settings") }
        controller.approvePermissionChange(stale)
        let staleMode = try mode()
        try NotchChecks.require(staleMode == 0o644 && !controller.ready && controller.error == ClaudeSetupError.changed.rawValue,
                               "Stale approval repaired a replaced file")
        controller.configure(configurationRoot: client, policyReviewed: true)
        let approved = controller.permissionChange!
        let other = root.appendingPathComponent("other-client")
        controller.configure(configurationRoot: other, policyReviewed: true)
        try NotchChecks.require(controller.permissionChange == approved && !FileManager.default.fileExists(atPath: other.path),
                               "A different root replaced the pending approval")
        controller.approvePermissionChange(approved)
        let approvedMode = try mode()
        let approvedContents = try PrivateFiles.read(settings)
        try NotchChecks.require(approvedMode == 0o600 && approvedContents == original,
                               "Permission approval edited contents before configuration")
        try await wait("Approved private settings did not finish setup") { controller.ready || controller.error != nil }
        try NotchChecks.require(controller.ready && controller.configured && controller.permissionChange == nil &&
            controller.collectingSources == [.claudeCLI], "Permission approval did not continue CLI-only setup")
        controller.remove()
        let removedMode = try mode()
        let restored = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! NSDictionary
        let expected = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        try NotchChecks.require(!controller.cleanupNeeded && removedMode == 0o600 && restored == expected,
                               "Removal lost settings or widened the approved private permissions")
    }

    static func collection() async throws {
        let domain = "tokenotch-claude-app-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(domain)
        try PrivateFiles.directory(root)
        let appRoot = root.appendingPathComponent("app")
        let client = root.appendingPathComponent("selected-client")
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "vscodeMetricsEnabled")
        let controller = ClaudeCodeIntegrationController(defaults: defaults, root: appRoot,
            environment: { [:] }, managedPolicyPresent: { false })
        let model = TokenotchModel(defaults: defaults, root: appRoot, claudeIntegration: controller)
        defer {
            model.claude.stop(); model.vscode.stop()
            model.history.stop(); model.timeline.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        controller.configure(configurationRoot: client, policyReviewed: false)
        try NotchChecks.require(!controller.enabled && controller.error != nil &&
            !FileManager.default.fileExists(atPath: client.path), "Unreviewed setup changed the selected client")
        model.history.start(available: false)
        model.selectOnboardingClient(.claudeCLI)
        try NotchChecks.require(!model.hasOnboardingConnection, "Claude setup eligibility bypassed configuration")
        model.timeline.start(clients: [])
        model.history.setEnabled(true)
        model.history.setEnabled(true, provider: .claudeCode)
        model.timeline.setEnabled(true, provider: .claudeCode)
        model.vscode.start()
        model.configureClaude(configurationRoot: client, policyReviewed: true)
        try await wait("Independent receivers did not become ready") { controller.ready && model.vscode.ready }
        try NotchChecks.require(model.hasOnboardingConnection && model.isClientConfigured(.claudeCLI) &&
            !model.isClientConfigured(.claudeDesktop), "Metrics-only onboarding requires the wrong client capability")
        try await wait("Independently consented recording did not start") {
            model.history.recordingSources.isSuperset(of: [.claudeCLI, .vscodeLocal]) &&
                model.timeline.recordingClients.contains(.claudeCLI)
        }
        model.options.showClaudeNotch = false
        try NotchChecks.require(controller.ready && model.vscode.ready, "Hiding a provider disconnected collection")
        model.options.showClaudeNotch = true
        model.options.showCopilotBadge = false
        try NotchChecks.require(model.notchProviders == [.claudeCode] && controller.ready && model.vscode.ready &&
            model.history.recordingSources.isSuperset(of: [.claudeCLI, .vscodeLocal]) &&
            model.timeline.recordingClients.contains(.claudeCLI),
            "Claude-only visibility must not disconnect Copilot or pause either provider's recording")
        model.options.showClaudeNotch = false
        try NotchChecks.require(model.notchProviders.isEmpty && controller.ready && model.vscode.ready,
                               "Hiding both providers must hide only the notch, not collection")
        model.options.showCopilotBadge = true
        model.options.showClaudeNotch = true
        try NotchChecks.require(controller.configured &&
            controller.readiness(.claudeCLI).metrics.delivery(now: Date()) == .waiting &&
            controller.readiness(.claudeDesktop).metrics.delivery(now: Date()) == .unsupported &&
            controller.readiness(.claudeCLI).lifecycle.delivery(now: Date()) == .unverified,
            "Configuration certified delivery, Desktop or lifecycle")
        let receipt = try ClaudeCodeInstallation(root: appRoot).receipt()!
        let vscodeConfig = try JSONDecoder().decode(TelemetryConfiguration.self,
            from: PrivateFiles.read(appRoot.appendingPathComponent("vscode-telemetry.json"))!)
        let now = Date()
        let claude = try ClaudeCodeChecks.fixture(at: now)
        let status = try await send(claude, config: receipt.configuration, source: .claudeCLI)
        try NotchChecks.require(status == 200, "Claude usage request failed")
        _ = try await send(claude, config: receipt.configuration, source: .claudeCLI)
        let copilot = try TelemetryChecks.fixture(model: "shared-model", at: now)
        _ = try await send(copilot, config: vscodeConfig, source: .vscodeLocal)
        try NotchChecks.require(model.history.selectedProvider == nil, "The first two-provider connection did not open an all-provider overview")
        model.history.selectedProvider = .copilot
        try NotchChecks.require(controller.accepted == 2 && model.tokenTotals?.total == 110,
                               "Claude was mislabeled as Copilot or a replay inflated live usage")
        model.history.selectedProvider = .claudeCode
        try NotchChecks.require(model.tokenTotals?.total == 170 && model.modelTokenTotals.first?.provider == .claudeCode,
                               "Provider switching retained Copilot live totals")
        model.history.selectedProvider = nil
        try NotchChecks.require(model.tokenTotals?.total == 280 && model.modelTokenTotals.count == 2 &&
            Set(model.modelTokenTotals.map(\.id)).count == 2, "All-providers model identities collided")
        model.history.tick(now: Date())
        model.timeline.tick(now: Date())
        let calendar = HistoryCalendar(zone: TimeZone(identifier: model.history.zone)!)
        let interval = calendar.interval(.today, selected: now, now: now)
        let savedClaude = try await model.history.read(interval, model: nil, provider: .claudeCode)
        let savedCopilot = try await model.history.read(interval, model: nil, provider: .copilot)
        try NotchChecks.require(savedClaude?.totals.total == 170 && savedClaude?.totals.costReportedCalls == 1 &&
            savedCopilot?.totals.total == 110,
            "Application routing lost consented history: Claude=\(savedClaude?.totals.total.description ?? "nil"), costCalls=\(savedClaude?.totals.costReportedCalls.description ?? "nil"), Copilot=\(savedCopilot?.totals.total.description ?? "nil"), error=\(model.history.error ?? "none")")
        model.history.selectedSource = .vscodeLocal
        let frozen = try await model.history.read(interval, model: nil, scope: HistoryQueryScope(provider: .claudeCode, source: nil))
        try NotchChecks.require(frozen?.totals.total == 170 && model.history.error == nil,
                               "A filter transition changed an already captured query scope")
        model.history.selectedSource = .claudeCLI
        try await wait("Claude source-filtered saved summary did not load") { !model.history.notchLoading }
        let scopedCard = NotchPresentation(model: model)
        try NotchChecks.require(scopedCard.provider == .claudeCode && scopedCard.savedUsage?.totals.total == 170 &&
            scopedCard.usageTotals?.costCoverage.value == 123456,
            "All providers with a Claude client filter hid saved usage or reported cost")
        model.history.selectedSource = nil
        model.timeline.selectedProvider = .claudeCode
        try await wait("Claude session list did not load") { model.timeline.sessions.count == 1 }
        try NotchChecks.require(model.timeline.sessions[0].source == .claudeCLI, "Saved Claude session was relabeled")
        let unsupported = try ClaudeCodeChecks.fixture(service: "claude-code-desktop", entry: nil, request: "desktop", at: Date())
        _ = try await send(unsupported, config: receipt.configuration, source: .claudeCLI)
        try NotchChecks.require(controller.rejected == 0 && controller.excluded > 0 &&
            controller.readiness(.claudeCLI).metrics.delivery(now: Date()) == .receiving,
            "Excluded client traffic poisoned CLI readiness")
        let settings = client.appendingPathComponent("settings.json")
        let originalSettings = try PrivateFiles.read(settings)
        controller.stop()
        try ClaudeCodeChecks.addLegacyAttribution(ClaudeCodeInstallation(root: appRoot))
        let restarted = ClaudeCodeIntegrationController(defaults: defaults, root: appRoot,
            environment: { [:] }, managedPolicyPresent: { false })
        defer { restarted.stop() }
        restarted.start()
        try await wait("Claude receiver restart did not recover its stable endpoint") { restarted.ready || restarted.error != nil }
        let restartedSettings = try PrivateFiles.read(settings)
        try NotchChecks.require(restarted.ready && restartedSettings == originalSettings &&
            restarted.readiness(.claudeCLI).metrics.delivery(now: Date()) == .waiting,
            "Restart rewrote client settings or fabricated delivery")
        restarted.stop()
        let blocker = OTLPReceiver(provider: .claudeCode)
        var blockerReady = false
        blocker.onReady = { _ in Task { @MainActor in blockerReady = true } }
        defer { blocker.stop() }
        try blocker.start(receipt.configuration)
        try await wait("Synthetic port blocker did not start") { blockerReady }
        restarted.start()
        try await wait("A conflicting receiver port was not reported") { restarted.error != nil }
        try NotchChecks.require(!restarted.ready && model.vscode.ready, "Claude failure interrupted Copilot")
        blocker.stop()
        restarted.retry()
        try await wait("Retry did not recover the owned endpoint") { restarted.ready || restarted.error != nil }
        try NotchChecks.require(restarted.ready, "Retry after a port conflict failed")
        restarted.remove()
        try NotchChecks.require(!restarted.enabled && !restarted.cleanupNeeded && model.vscode.ready,
                               "Removing Claude disturbed Copilot or left owned settings")
        _ = try await send(copilot, config: vscodeConfig, source: .vscodeLocal)
        try NotchChecks.require(model.vscode.accepted[.vscodeLocal] == 2 && model.history.isEnabled(.claudeCode),
                               "Claude removal stopped Copilot or changed recording consent")
        let retained = try await model.history.read(interval, model: nil, provider: .claudeCode)
        try NotchChecks.require(retained?.totals.total == 170,
                               "Disconnect deleted retained Claude history")
    }

    static func costAndModelUpdates() async throws {
        let domain = "tokenotch-claude-cost-updates-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(domain)
        try PrivateFiles.directory(root)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "vscodeMetricsEnabled")
        let appRoot = root.appendingPathComponent("app")
        let controller = ClaudeCodeIntegrationController(defaults: defaults, root: appRoot,
            environment: { [:] }, managedPolicyPresent: { false })
        let model = TokenotchModel(defaults: defaults, root: appRoot, claudeIntegration: controller)
        model.options.showCopilotBadge = false
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let fleet = NotchFleet(model: model, openSettings: {}, isFullScreen: { _ in false },
            pointerLocation: { CGPoint(x: -100_000, y: -100_000) })
        defer {
            fleet.stop()
            model.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        model.history.start(available: false)
        model.history.setEnabled(true, provider: .claudeCode)
        controller.configure(configurationRoot: root.appendingPathComponent("client"), policyReviewed: true)
        try await wait("Claude cost fixture did not start recording") {
            controller.ready && model.history.recordingSources.contains(.claudeCLI)
        }
        let config = try ClaudeCodeInstallation(root: appRoot).receipt()!.configuration
        let sonnet = try ClaudeCodeChecks.fixture(request: "req_cost_sonnet", at: Date(), fields: [
            "model": ["stringValue": "claude-sonnet-4-5"]
        ])
        _ = try await send(sonnet, config: config, source: .claudeCLI)
        model.vscode.onBatch?(try CopilotOTelNormalizer.decode(
            TelemetryChecks.fixture(at: Date()), source: .vscodeLocal, now: Date()))
        model.history.selectedProvider = .claudeCode
        try await wait("Initial Claude cost was not published") {
            model.history.todayUsage?.totals.costCoverage.value == 123456
        }
        fleet.start()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        try await wait("Claude cost fixture notch did not appear") {
            NSApplication.shared.windows.contains {
                $0.isVisible && !before.contains(ObjectIdentifier($0)) &&
                    ($0 as? NotchPanel)?.acceptsKeyboardFocus == false
            }
        }
        fleet.reveal()
        func card() -> ShapeHostingView<CopilotSummaryView>? {
            NSApplication.shared.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
                .compactMap { $0.contentView as? ShapeHostingView<CopilotSummaryView> }.first
        }
        try await wait("Initial Claude cost card did not open") { card() != nil }
        let initial = card()!.rootView.presentation
        try NotchChecks.require(initial.sessionRows.count == 1 &&
            initial.sessionRows.allSatisfy { $0.target.source == .claudeCLI && $0.label.hasPrefix("Claude Code CLI ") },
            "Claude's own sessions were mislabeled as VS Code sessions")
        let haiku = try ClaudeCodeChecks.fixture(request: "req_cost_haiku", at: Date(), cost: nil, fields: [
            "model": ["stringValue": "claude-haiku-4-5-20251001"],
            "cost_usd": ["doubleValue": 0.0000025]
        ])
        _ = try await send(haiku, config: config, source: .claudeCLI)
        _ = try await send(haiku, config: config, source: .claudeCLI)
        try await wait("A model switch did not update cost and Haiku metrics in the open notch") {
            guard let data = card()?.rootView.presentation else { return false }
            return data.usageTotals?.costCoverage.value == 123459 &&
                data.usageTotals?.calls == 2 &&
                data.allModelRows.contains { $0.model == "claude-haiku-4-5-20251001" && $0.calls == 1 }
        }
        try NotchChecks.require(model.liveLedger(provider: .claudeCode).totals?.costCoverage.value == 123459 &&
            model.liveLedger(provider: .copilot).totals?.costCoverage.value == nil,
            "Updated cost must agree across live and saved data without including Copilot calls or replaying requests")
        let rejected = try ClaudeCodeChecks.fixture(request: "req_cost_invalid", at: Date(), cost: "invalid")
        _ = try await send(rejected, config: config, source: .claudeCLI)
        try await wait("Rejected usage left an apparently healthy frozen cost") {
            card()?.rootView.presentation.metricsWarning?.contains("invalid estimated cost") == true
        }
        try NotchChecks.require(card()?.rootView.presentation.usageTotals?.costCoverage.value == 123459,
                               "Rejected usage must preserve the last valid cost, not invent or erase it")
        let content = VStack {
            LiveSessionsSection(model: model)
            CopilotSummaryContent(presentation: card()!.rootView.presentation, openClient: { _ in }, openHistory: {})
        }.frame(width: 520).padding(20).background(.black)
        let image = try NotchChecks.hostedImage(content, size: NSHostingView(rootView: content).fittingSize)
        guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Claude model update render unavailable") }
        let text = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: cgImage).perform([text])
        let visible = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        try NotchChecks.require(visible.contains("claude code cli") && visible.contains("haiku") &&
            visible.contains("invalid estimated cost") && !visible.contains("vs code"),
            "Claude's Settings and notch must show the switched model, correct client and rejected-usage warning")
    }

    static func account() async throws {
        let domain = "tokenotch-claude-account-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(domain)
        try PrivateFiles.directory(root)
        let defaults = ClaudeAccountDefaults(suiteName: domain)!
        let executable = try ClaudeCodeChecks.accountFixture(root: root)
        var opened: [URL] = []
        let account = ClaudeAccountController(defaults: defaults, root: root) { opened.append($0); return true }
        defer {
            account.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        account.executable = executable.path
        let configuration = root.appendingPathComponent("client")
        try NotchChecks.require(!account.enabled && account.authentication == nil && opened.isEmpty,
                               "Browsing account controls enabled authentication")
        account.signIn(configurationRoot: configuration)
        guard let launcher = opened.first else { throw NotchCheckFailure.failed("Sign-in did not open its Terminal launcher") }
        let script = String(decoding: try PrivateFiles.read(launcher)!, as: UTF8.self)
        try NotchChecks.require(script.contains("auth login") && script.contains("/usr/bin/env -i") &&
            account.authentication == nil, "Sign-in used private APIs or fabricated authentication")
        account.connect(configurationRoot: configuration)
        try await wait("Claude account check did not finish") { !account.busy }
        try NotchChecks.require(account.authentication?.signedIn == true && account.status == "Signed in to Claude" &&
            !FileManager.default.fileExists(atPath: launcher.path),
            "Official auth status was not read or the temporary launcher was retained")
        account.disconnect()
        try NotchChecks.require(!account.enabled && account.authentication == nil &&
            account.status.contains("login is unchanged"), "Stopping account checks affected shared CLI sign-in")
        defaults.forceAccount = true
        defaults.set(true, forKey: "DisableAccountConnection")
        account.signIn(configurationRoot: configuration)
        try NotchChecks.require(!account.enabled && opened.count == 1 && account.status.contains("managed policy"),
                               "Claude sign-in bypassed the managed account policy")
    }

    static func sessionClosure() async throws {
        let domain = "tokenotch-claude-session-closure-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent(domain)
        try PrivateFiles.directory(root)
        let defaults = UserDefaults(suiteName: domain)!
        let appRoot = root.appendingPathComponent("app")
        let controller = ClaudeCodeIntegrationController(defaults: defaults, root: appRoot,
            environment: { [:] }, managedPolicyPresent: { false })
        let model = TokenotchModel(defaults: defaults, root: appRoot, claudeIntegration: controller)
        let bridge = LocalBridge(root: appRoot)
        defer {
            bridge.stop()
            controller.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        controller.configure(configurationRoot: root.appendingPathComponent("client"), policyReviewed: true)
        try await wait("Claude session fixture did not become ready") { controller.ready || controller.error != nil }
        try NotchChecks.require(controller.ready, "Claude session fixture setup failed")
        model.history.selectedProvider = .claudeCode
        let now = Date()
        for session in ["synthetic-session", "second-session"] {
            controller.onBatch?(try ClaudeCodeOTelNormalizer.decode(
                ClaudeCodeChecks.fixture(session: session, request: session, at: now), now: now))
        }
        let end = try ClaudeSessionEvent.parse(ClaudeCodeChecks.sessionHookFixture("SessionEnd"),
                                               hook: "SessionEnd", now: Date())!
        controller.receiveSession(end)
        try NotchChecks.require(model.sessionMetrics.count == 2, "Metrics consent enabled lifecycle collection")
        controller.enableSessionTracking(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        try NotchChecks.require(controller.sessionTrackingEnabled && controller.sessionTrackingError == nil,
                               "Claude session tracking could not be enabled")
        bridge.onClaudeSession = { event in Task { @MainActor in controller.receiveSession(event) } }
        try bridge.start()
        for session in ["synthetic-session", "second-session"] {
            let start = try ClaudeSessionEvent.parse(ClaudeCodeChecks.sessionHookFixture("SessionStart", session: session),
                                                     hook: "SessionStart", now: Date())!
            try LocalBridge.send(start, root: appRoot)
        }
        try await wait("Session starts did not cross the bridge") { controller.sessionState.openSessions.count == 2 }
        let windows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let fleet = NotchFleet(model: model, openSettings: {}, isFullScreen: { _ in false })
        defer { fleet.stop() }
        func card() -> CopilotSummaryView? {
            NSApplication.shared.windows.filter { $0.isVisible && !windows.contains(ObjectIdentifier($0)) }
                .compactMap { ($0.contentView as? ShapeHostingView<CopilotSummaryView>)?.rootView }.first
        }
        fleet.start()
        var prepared = false
        DispatchQueue.main.async { prepared = true }
        try await wait("Notch setup did not drain its queued rebuild") { prepared }
        fleet.reveal()
        try await wait("Claude session rows did not appear in the open notch card") {
            card()?.presentation.sessionRows.count == 2
        }
        var idle = NotchPresentation(model: model, provider: .claudeCode)
        idle.now = now.addingTimeInterval(600)
        try NotchChecks.require(idle.sessionRows.count == 2, "Idle open Claude sessions were hidden by inactivity")
        let closed = try ClaudeSessionEvent.parse(ClaudeCodeChecks.sessionHookFixture("SessionEnd"),
                                                  hook: "SessionEnd", now: Date())!
        try LocalBridge.send(closed, root: appRoot)
        try await wait("SessionEnd did not remove the closed session immediately") {
            model.sessionMetrics.count == 1 && model.liveSessionMetrics(provider: .claudeCode).count == 1 &&
                card()?.presentation.sessionRows.count == 1 && card()?.presentation.activityTitle == "1 session reported"
        }
        let remaining = NotchPresentation(model: model, provider: .claudeCode)
        try NotchChecks.require(remaining.sessionRows.count == 1 && remaining.activityTitle == "1 session reported" &&
            remaining.sessionRows[0].target.liveHash != closed.session && model.tokenTotals?.calls == 2,
            "Closing one Claude session hid another session or removed usage totals")
        let later = Date()
        controller.onBatch?(try ClaudeCodeOTelNormalizer.decode(
            ClaudeCodeChecks.fixture(request: "late-call", at: later), now: later))
        controller.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        controller.receiveStatusLine(try ClaudeStatusLineSnapshot.parse(
            ClaudeCodeChecks.statusLineFixture(at: later), now: later))
        try NotchChecks.require(model.sessionMetrics.count == 1 && model.tokenTotals?.calls == 3 &&
            model.liveLedger(provider: .claudeCode).bySession.count == 2 &&
            NotchPresentation(model: model, provider: .claudeCode).sessionRows.count == 1,
            "Late usage or context resurrected an ended session or lost its accounting")
        let resumed = try ClaudeSessionEvent.parse(ClaudeCodeChecks.sessionHookFixture("SessionStart"),
                                                   hook: "SessionStart", now: Date())!
        try LocalBridge.send(resumed, root: appRoot)
        try await wait("Explicitly resumed Claude session remained hidden") {
            model.sessionMetrics.count == 2 && card()?.presentation.sessionRows.count == 2
        }
        let endedAgain = try ClaudeSessionEvent.parse(ClaudeCodeChecks.sessionHookFixture("SessionEnd"),
                                                      hook: "SessionEnd", now: Date())!
        try LocalBridge.send(endedAgain, root: appRoot)
        try await wait("Resumed session did not close again") { model.sessionMetrics.count == 1 }
        controller.disableSessionTracking()
        try NotchChecks.require(!controller.sessionTrackingEnabled && controller.statusLineEnabled && controller.ready &&
            model.tokenTotals?.calls == 3 && model.sessionMetrics.count == 1,
            "Disabling tracking resurrected a closed session or changed quota consent or usage collection")
        try ClaudeCodeChecks.rejects { try LocalBridge.send(closed, root: appRoot) }
        controller.remove()
    }

    static func sessionFreshness() throws {
        let now = ClaudeCodeChecks.now
        let stale = now.addingTimeInterval(-301)
        var ledger = TokenLedger()
        for (session, request, date): (String?, String, Date) in [
            ("closed-session", "closed-call", stale),
            ("recent-session", "recent-call", now),
            (nil, "unlinked-call", now)
        ] {
            let batch = try ClaudeCodeOTelNormalizer.decode(
                ClaudeCodeChecks.fixture(session: session, request: request, at: date), now: date)
            for event in batch.events { try ledger.observe(event, now: date) }
        }
        var statusLine = ClaudeStatusLineState()
        let oldContext = try ClaudeStatusLineSnapshot.parse(
            ClaudeCodeChecks.statusLineFixture(session: "context-only-session", at: stale), now: stale)
        try statusLine.observe(oldContext, now: stale)
        var data = NotchPresentation(tokens: ledger.totals, now: now, models: ledger.byModel)
        data.provider = .claudeCode
        data.metricSessions = statusLine.merging(ledger.bySession, provider: .claudeCode, source: nil, now: now)
        let recentID = ActivityEvent.digest("claudeCode:session:recent-session")
        try NotchChecks.require(data.allSessionRows.map(\.target.liveHash) == [recentID] &&
            data.activityTitle == "1 session reported",
            "Claude notch retained stale usage/context sessions or counted unlinked calls")
        data.now = now.addingTimeInterval(300)
        try NotchChecks.require(data.sessionRows.count == 1, "Claude session expired before its freshness boundary")
        data.now = now.addingTimeInterval(301)
        ledger.expire(now: data.now)
        try NotchChecks.require(data.sessionRows.isEmpty && data.allSessionRows.isEmpty &&
            data.activityTitle == "No recent sessions reported" &&
            data.usageTotals?.calls == 3 && data.usageTotals?.total == ledger.totals?.total &&
            ledger.bySession.count == 3 && ledger.byModel.count == 1,
            "Expiring Claude notch sessions left stale rows/counts or discarded retained usage")
        let resumed = try ClaudeStatusLineSnapshot.parse(
            ClaudeCodeChecks.statusLineFixture(session: "closed-session", at: data.now), now: data.now)
        try statusLine.observe(resumed, now: data.now)
        data.metricSessions = statusLine.merging(ledger.bySession, provider: .claudeCode, source: nil, now: data.now)
        try NotchChecks.require(data.sessionRows.map(\.target.liveHash) == [resumed.session] &&
            data.activityTitle == "1 session reported" &&
            data.context(for: data.sessionRows[0].target)?.usage.currentTokens == 40_000 &&
            data.usageTotals?.calls == 3,
            "A fresh Claude status-line report did not restore its session without duplicating usage")
    }

    static func presentation(directory: URL?) throws {
        let reading = CopilotRingReading(quota: try NotchChecks.account().primaryQuota, isStale: false, isWorking: false)
        for edge in NotchEdge.allCases {
            for scale: CGFloat in [0.75, 1, 1.5] {
                let size = NotchLayout.size(edge: edge, scale: scale, providerCount: 2)
                let first = NotchLayout.ringCenter(in: size, edge: edge, scale: scale)
                let second = NotchLayout.ringCenter(in: size, edge: edge, scale: scale, index: 1)
                try NotchChecks.require(CGRect(origin: .zero, size: size).contains(first) &&
                    CGRect(origin: .zero, size: size).contains(second) &&
                    hypot(first.x - second.x, first.y - second.y) > NotchLayout.ringDiameter * scale,
                    "Provider cells overlap or escape the notch")
                for collapsed in [false, true] {
                    let image = try NotchChecks.hostedImage(ProviderNotchBadge(providers: [.copilot, .claudeCode],
                        reading: reading, edge: edge, scale: scale, isCollapsed: collapsed, open: { _ in }), size: size)
                    try NotchChecks.save(image, name: "providers-\(edge.rawValue)-\(scale)-\(collapsed)", directory: directory)
                }
            }
        }
        let now = Date()
        let batch = try ClaudeCodeOTelNormalizer.decode(ClaudeCodeChecks.fixture(at: now), now: now)
        var ledger = TokenLedger()
        for event in batch.events { try ledger.observe(event, now: now) }
        var data = NotchPresentation(tokens: ledger.totals, now: now, models: ledger.byModel)
        data.provider = .claudeCode
        data.liveTimeline = ledger.hourlyTimeline(now: now)
        let content = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {})
            .frame(width: 310).padding(20).background(.black)
        let image = try NotchChecks.hostedImage(content, size: NSHostingView(rootView: content).fittingSize)
        try NotchChecks.save(image, name: "claude-metrics-card", directory: directory)
    }

    static func interactions() throws {
        guard NSScreen.main != nil else { throw NotchCheckFailure.failed("Provider interactions require a display") }
        let domain = "tokenotch-provider-interaction-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "claudeMetricsEnabled")
        defaults.set(true, forKey: "vscodeMetricsEnabled")
        let model = TokenotchModel(defaults: defaults, root: root)
        model.options.autoHideNotch = false
        var pointer = CGPoint(x: -100_000, y: -100_000)
        var fullScreen = false
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let fleet = NotchFleet(model: model, openSettings: {},
            isFullScreen: { _ in fullScreen }, pointerLocation: { pointer })
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        for edge in NotchEdge.allCases {
            model.options.edge = edge.rawValue
            fleet.start()
            try NotchChecks.drainMainQueue()
            guard let panel = NSApplication.shared.windows.compactMap({ $0 as? NotchPanel }).first(where: {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.acceptsKeyboardFocus
            }) else { throw NotchCheckFailure.failed("No two-provider notch panel") }
            let first = NotchLayout.ringCenter(in: panel.frame.size, edge: edge, scale: 1)
            let second = NotchLayout.ringCenter(in: panel.frame.size, edge: edge, scale: 1, index: 1)
            func screenPoint(_ point: CGPoint) -> CGPoint {
                CGPoint(x: panel.frame.minX + point.x, y: panel.frame.maxY - point.y)
            }
            guard let hit = panel.contentView as? ShapeHitTesting else { throw NotchCheckFailure.failed("Missing shape hit testing") }
            try NotchChecks.require(hit.contains(screenPoint: screenPoint(first)) && hit.contains(screenPoint: screenPoint(second)),
                                   "One provider cell cannot be hit on \(edge)")
            pointer = screenPoint(second)
            try NotchChecks.click(panel, at: CGPoint(x: second.x, y: panel.frame.height - second.y))
            func card() -> ShapeHostingView<CopilotSummaryView>? {
                NSApplication.shared.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
                    .compactMap { $0.contentView as? ShapeHostingView<CopilotSummaryView> }.first
            }
            try NotchChecks.waitUntil("Claude cell click did not select its card") { card()?.rootView.presentation.provider == .claudeCode }
            pointer = screenPoint(first)
            try NotchChecks.click(panel, at: CGPoint(x: first.x, y: panel.frame.height - first.y))
            try NotchChecks.waitUntil("Copilot cell click retained Claude data") { card()?.rootView.presentation.provider == .copilot }
            fullScreen = true
            fleet.reveal(allowSettings: false)
            try NotchChecks.require(!panel.isVisible && card() == nil && model.claude.enabled,
                                   "Full-screen folding exposed a card or disconnected Claude")
            fullScreen = false
            fleet.stop()
            try NotchChecks.drainMainQueue()
        }

    }

    static func keyboardFocus() throws {
        let domain = "tokenotch-provider-focus-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "claudeMetricsEnabled")
        let model = TokenotchModel(defaults: defaults, root: root)
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let fleet = NotchFleet(model: model, openSettings: {}, isFullScreen: { _ in false })
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        fleet.start()
        try NotchChecks.drainMainQueue()
        fleet.reveal(keyboard: true)
        func card() -> NSWindow? {
            NSApplication.shared.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible &&
                    $0.contentView is ShapeHostingView<CopilotSummaryView>
            }
        }
        try NotchChecks.waitUntil("Native provider keyboard focus unavailable", diagnostics: {
            "card=\(card() != nil), canBecomeKey=\(card()?.canBecomeKey == true), keyWindow=\(NSApplication.shared.keyWindow?.className ?? "none")"
        }) { card()?.isKeyWindow == true }
    }
}
