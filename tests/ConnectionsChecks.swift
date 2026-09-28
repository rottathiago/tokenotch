import AppKit
import TokenotchCore
import SwiftUI
import Vision
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum ConnectionsChecks {
    static func readiness() throws {
        let now = Date()
        try NotchChecks.require(ConnectionReadiness.activity(installed: false, approved: false, observed: nil, now: now) == .off,
                                "Uninstalled activity must start off")
        try NotchChecks.require(ConnectionReadiness.activity(installed: true, approved: false, observed: nil, now: now) == .needsSetup,
                                "A native hook file alone must not claim VS Code setup is approved")
        try NotchChecks.require(ConnectionReadiness.activity(installed: true, approved: true, observed: nil, now: now) == .waiting,
                                "Approved settings must await real events")
        try NotchChecks.require(ConnectionReadiness.activity(installed: true, approved: false, observed: now, now: now) == .receiving,
                                "Real observations establish delivery even for installations from earlier versions")
        try NotchChecks.require(ConnectionReadiness.activity(installed: true, approved: true,
            observed: now.addingTimeInterval(-301), now: now) == .stale, "Old observations cannot claim recent delivery")
        try NotchChecks.require(ConnectionReadiness.usage(enabled: false, approved: true, ready: true, observed: now, now: now) == .off,
                                "Turning usage off must supersede past delivery")
        try NotchChecks.require(ConnectionReadiness.usage(enabled: true, approved: false, ready: true, observed: nil, now: now) == .needsSetup,
                                "Starting the receiver is not successful setup")
        try NotchChecks.require(ConnectionReadiness.usage(enabled: true, approved: true, ready: false, observed: now, now: now) == .unavailable,
                                "An unavailable receiver cannot claim a working connection")
        try NotchChecks.require(ConnectionReadiness.usage(enabled: true, approved: true, ready: true, observed: nil, now: now) == .waiting,
                                "Configuration is not verified usage")
        try NotchChecks.require(ConnectionReadiness.usage(enabled: true, approved: false, ready: true, observed: now, now: now) == .receiving,
                                "Existing live usage must not require reapproval just for a new UI")
    }

    static func setup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-connections-\(UUID().uuidString)")
        let suite = "tokenotch-connections-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NotchCheckFailure.failed("Fixture defaults") }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var opened: [URL] = []
        let integration = VSCodeIntegrationController(defaults: defaults, root: root) { opened.append($0); return true }
        defer { integration.stop() }
        try NotchChecks.require(!integration.enabled && !integration.setupIncludesUsage && !integration.activityConfigured,
                                "Fresh setup must default to activity only, without starting collection")
        integration.setupIncludesUsage = true
        try NotchChecks.require(!integration.enabled && !integration.ready,
                                "Selecting optional usage must not start it before consent")
        integration.configure(metrics: false)
        try NotchChecks.require(integration.phase == .awaitingApproval && integration.isWorking && !integration.enabled,
                                "Activity setup must await explicit VS Code approval without enabling usage")
        guard let first = integration.pendingRequest else { throw NotchCheckFailure.failed("Missing setup request") }
        let requestFile = root.appendingPathComponent("vscode-setup-request.json")
        let original = try PrivateFiles.read(requestFile)
        try NotchChecks.require(!first.metrics && first.hooks && first.endpoints == nil,
                                "Unchecked usage must not create telemetry settings")
        integration.configure(metrics: true)
        integration.remove(hooks: true)
        try NotchChecks.require(integration.pendingRequest?.nonce == first.nonce && !integration.enabled && integration.error != nil,
                                "Repeated actions must not replace an open consent request")
        let unchanged = try PrivateFiles.read(requestFile)
        try NotchChecks.require(unchanged == original,
                                "The pending request must remain unchanged")
        integration.openApproval()
        try NotchChecks.require(opened.count == 2 && opened.first == opened.last, "Reopening approval must reuse the original nonce")

        func result(_ status: String, nonce: String? = nil, operation: String? = nil) throws {
            guard let request = integration.pendingRequest else { throw NotchCheckFailure.failed("Result without a request") }
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 1, "nonce": nonce ?? request.nonce, "operation": operation ?? request.operation, "status": status
            ])
            try PrivateFiles.write(data, to: root.appendingPathComponent("vscode-setup-result.json"))
            integration.tick()
        }
        try result("configured", nonce: String(repeating: "0", count: 64))
        try result("configured", operation: "remove")
        try NotchChecks.require(integration.phase == .awaitingApproval && !integration.activityConfigured,
                                "Unrelated results cannot advance setup")
        try result("blocked")
        try NotchChecks.require(integration.phase == .blocked && !integration.isWorking && !integration.activityConfigured,
                                "Blocked setup must remain retryable and unconfigured")
        integration.configure(metrics: false)
        try result("cancelled")
        try NotchChecks.require(integration.phase == .cancelled && !integration.activityConfigured, "Cancellation is not approval")
        integration.configure(metrics: false)
        try result("configured")
        try NotchChecks.require(integration.phase == .configured && integration.activityConfigured && !integration.usageConfigured,
                                "Activity approval must not imply usage approval")
        integration.configure(metrics: true)
        try NotchChecks.waitUntil { integration.pendingRequest != nil }
        try NotchChecks.require(integration.enabled && integration.ready && integration.pendingRequest?.metrics == true,
                                "Opted-in usage should prepare a private receiver and request both capabilities")
        try NotchChecks.require(!integration.usageConfigured, "Listening does not imply settings approval")
        try result("configured")
        try NotchChecks.require(integration.usageConfigured && integration.lastObservation.isEmpty,
                                "Approved usage must still wait for actual delivery")
        let restored = VSCodeIntegrationController(defaults: defaults, root: root, openSetupURL: { _ in false })
        defer { restored.stop() }
        try NotchChecks.require(restored.activityConfigured && restored.usageConfigured && restored.enabled,
                                "Remember approvals and consent across app restarts without inventing observations")
        integration.remove(hooks: false)
        try NotchChecks.require(!integration.enabled && !integration.setupIncludesUsage && integration.pendingRequest?.hooks == false,
                                "Turning usage off must preserve activity and stop the receiver immediately")
        try result("blocked")
        try NotchChecks.require(integration.usageRemovalNeeded && !integration.enabled,
                                "Failed removal must remain visible and retryable even after the receiver stops")
        let interrupted = VSCodeIntegrationController(defaults: defaults, root: root, openSetupURL: { _ in true })
        defer { interrupted.stop() }
        try NotchChecks.require(interrupted.usageRemovalNeeded && !interrupted.enabled,
                                "Pending cleanup must survive app restarts")
        integration.remove(hooks: false)
        try result("removed")
        try NotchChecks.require(integration.activityConfigured && !integration.usageConfigured
                                && !integration.usageRemovalNeeded && integration.phase == .removed,
                                "Usage-only removal must preserve the activity setup")
        integration.remove(hooks: true)
        try result("removed")
        try NotchChecks.require(!integration.activityConfigured && !integration.activityRemovalNeeded,
                                "Full removal must clear the remembered activity approval and cleanup state")
        restored.configure(metrics: false)
        try NotchChecks.require(restored.phase == .awaitingApproval && restored.pendingRequest != nil && restored.error != nil,
                                "A failed editor handoff must keep an actionable, reusable approval request")
    }

    static func render(directory: URL? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-connections-render-\(UUID().uuidString)")
        let suite = "tokenotch-connections-render-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NotchCheckFailure.failed("Fixture defaults") }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = TokenotchModel(defaults: defaults, root: root)
        for scheme in [ColorScheme.light, .dark] {
            let image = try NotchChecks.hostedImage(ConnectionsView(model: model).environment(\.colorScheme, scheme),
                                                  size: CGSize(width: 620, height: 520))
            try NotchChecks.save(image, name: "connections-\(scheme)", directory: directory)
            guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Connections image missing") }
            let request = VNRecognizeTextRequest()
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            try NotchChecks.require(text.contains("Copilot CLI") && text.contains("Visual Studio Code"),
                                    "Both clients must be visible at the minimum settings width")
            try NotchChecks.require(text.contains("Set up Copilot CLI") && text.contains("Set up VS Code"),
                                    "Both primary setup actions must be visible without opening technical details")
            try NotchChecks.require(!text.contains("VS Code usage") && !text.contains("Consent & install")
                                    && !text.contains("Enterprise user budget"),
                                    "Do not restore duplicate integration sections or technical controls in the primary view")
        }
        for client in Client.allCases {
            let image = try NotchChecks.hostedImage(ConnectionSetupView(model: model, client: client)
                .environment(\.colorScheme, .light), size: CGSize(width: 510, height: 450))
            try NotchChecks.save(image, name: "connections-setup-\(client.rawValue)", directory: directory)
            guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Setup image missing") }
            let request = VNRecognizeTextRequest()
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            try NotchChecks.require(text.contains(client == .cli ? "Connect Copilot CLI" : "Install setup extension"),
                                    "The next setup action must remain visible")
            if client == .vscode {
                try NotchChecks.require(text.contains("Include model") && text.contains("off by default"),
                                        "The optional usage choice and its default must be visible in setup")
            }
        }
        try NotchChecks.require(!model.vscode.enabled && !model.vscode.setupIncludesUsage,
                                "Opening and rendering setup must not opt into usage")
        try NotchChecks.require(!FileManager.default.fileExists(atPath: root.path),
                                "Opening Connections must not install or configure anything")
    }

    static func configurationStates(directory: URL? = nil) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-connection-status-\(UUID().uuidString)")
        let suite = "tokenotch-connection-status-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NotchCheckFailure.failed("Fixture defaults") }
        let dataRoot = root.appendingPathComponent("data")
        let bundle = root.appendingPathComponent("Fixture.app")
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        let extensions = bundle.appendingPathComponent("Contents/Resources/CopilotUsage")
        let installation = HookInstallation(root: dataRoot, cliHome: root.appendingPathComponent("copilot"))
        var models: [TokenotchModel] = []
        defer {
            models.forEach { $0.stop() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data("Fixture helper; never executed".utf8).write(to: helpers.appendingPathComponent("TokenotchHook"))
        try Data("export const fixture = true;".utf8).write(to: extensions.appendingPathComponent("extension.mjs"))

        func makeModel() -> TokenotchModel {
            let model = TokenotchModel(defaults: defaults, root: dataRoot, installation: installation,
                                   bundleURL: bundle, openSetupURL: { _ in true })
            models.append(model)
            return model
        }

        func capture(_ model: TokenotchModel, _ name: String, configured: Set<Client>) throws {
            for scheme in [ColorScheme.light, .dark] {
                let image = try NotchChecks.hostedImage(ConnectionsView(model: model).environment(\.colorScheme, scheme),
                                                      size: CGSize(width: 620, height: 520))
                try NotchChecks.save(image, name: "connections-status-\(name)-\(scheme)", directory: directory)
                guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Connections image missing") }
                let request = VNRecognizeTextRequest()
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                let observations = request.results ?? []
                for client in Client.allCases {
                    let title = client == .cli ? "Copilot CLI" : "Visual Studio Code"
                    guard let heading = observations.first(where: {
                        $0.topCandidates(1).first?.string.contains(title) == true
                    }) else { throw NotchCheckFailure.failed("Missing connection heading: \(title)") }
                    let row = observations.filter {
                        abs($0.boundingBox.midY - heading.boundingBox.midY) < 0.018
                    }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                    let expected = configured.contains(client) ? "configured" : "not configured"
                    try NotchChecks.require(row.contains(expected)
                        && (configured.contains(client) ? !row.contains("not configured") : true),
                        "\(name) must show \(title) as \(expected) beside its heading; found: \(row)")
                    try NotchChecks.require(model.isClientConfigured(client) == configured.contains(client),
                                            "Settings and setup must agree about \(title)")
                }
            }
        }

        let model = makeModel()
        try capture(model, "neither", configured: [])
        try NotchChecks.require(model.install(.cli), "Fixture CLI installation failed")
        try capture(model, "cli-only", configured: [.cli])
        model.configureVSCode(metrics: false)
        try capture(model, "approval-pending", configured: [.cli])
        guard let request = model.vscode.pendingRequest else { throw NotchCheckFailure.failed("Missing setup request") }
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: [
            "version": 1, "nonce": request.nonce, "operation": request.operation, "status": "configured"
        ]), to: dataRoot.appendingPathComponent("vscode-setup-result.json"))
        model.vscode.tick()
        try capture(model, "both-awaiting-data", configured: [.cli, .vscode])
        try NotchChecks.require(model.lastActivityEvent.isEmpty && !model.vscode.enabled,
                                "Both clients can be configured before delivery and without optional VS Code usage")
        model.clock = model.clock.addingTimeInterval(3600)
        try capture(model, "both-idle", configured: [.cli, .vscode])
        let restored = makeModel()
        try capture(restored, "restored", configured: [.cli, .vscode])
        let updatedExtension = Data("export const fixture = 'updated';".utf8)
        try updatedExtension.write(to: extensions.appendingPathComponent("extension.mjs"))
        try capture(restored, "cli-update-required", configured: [.vscode])
        try NotchChecks.require(restored.registeredClients.contains(.cli)
                                && restored.connectionSetupErrors[.cli]?.contains("out of date") == true,
                                "An owned but outdated extension must retain consent and explain how to repair setup")
        let installedExtension = try PrivateFiles.read(
            installation.cliHome.appendingPathComponent("extensions/tokenotch-token-usage/extension.mjs"))
        try NotchChecks.require(installedExtension != updatedExtension,
                                "Checking connection freshness must not silently change the installed extension")
        try NotchChecks.require(restored.install(.cli), "Fixture CLI update failed")
        try capture(restored, "cli-updated", configured: [.cli, .vscode])
        try NotchChecks.require(restored.connection[.cli]?.contains("each CLI session") == true,
                                "Repair must explain that existing sessions need to reload")
        try FileManager.default.removeItem(at: installation.cliHome.appendingPathComponent("extensions/tokenotch-token-usage/extension.mjs"))
        try capture(restored, "cli-needs-repair", configured: [.vscode])
        try NotchChecks.require(restored.connectionSetupErrors[.cli] != nil,
                                "Missing CLI setup files must be detected when Connections opens")
        try NotchChecks.require(restored.install(.cli), "Fixture CLI repair failed")
        restored.uninstall(.vscode)
        try capture(restored, "vscode-disconnected", configured: [.cli])
        restored.uninstall(.cli)
        try capture(restored, "both-disconnected", configured: [])
    }
}
