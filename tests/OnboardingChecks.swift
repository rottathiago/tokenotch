import AppKit
import TokenotchCore
import SwiftUI
import Vision
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

private final class OnboardingDefaults: UserDefaults, @unchecked Sendable {
    var forceHooks = false
    override func objectIsForced(forKey key: String) -> Bool {
        key == "DisableHooks" && forceHooks
    }
}

@MainActor
private final class OnboardingFixture {
    let domain = "tokenotch-onboarding-\(UUID().uuidString)"
    let directory: URL
    let root: URL
    let bundle: URL
    let installation: HookInstallation
    let defaults: OnboardingDefaults
    private var models: [TokenotchModel] = []
    var opened: [URL] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(domain)
        root = directory.appendingPathComponent("data")
        bundle = directory.appendingPathComponent("Fixture.app")
        installation = HookInstallation(root: root, cliHome: directory.appendingPathComponent("copilot"))
        guard let defaults = OnboardingDefaults(suiteName: domain) else {
            throw NotchCheckFailure.failed("Missing onboarding fixture defaults")
        }
        self.defaults = defaults
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        let extensions = bundle.appendingPathComponent("Contents/Resources/CopilotUsage")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data("Fixture helper; never executed".utf8).write(to: helpers.appendingPathComponent("TokenotchHook"))
        try Data("export const fixture = true;".utf8).write(to: extensions.appendingPathComponent("extension.mjs"))
    }

    func model() -> TokenotchModel {
        let model = TokenotchModel(defaults: defaults, root: root, installation: installation,
                              bundleURL: bundle, openSetupURL: { [weak self] url in
            self?.opened.append(url)
            return true
        })
        models.append(model)
        return model
    }

    func result(_ model: TokenotchModel, status: String, nonce: String? = nil) throws {
        guard let request = model.vscode.pendingRequest else { throw NotchCheckFailure.failed("Missing fixture approval") }
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: [
            "version": 1, "nonce": nonce ?? request.nonce, "operation": request.operation, "status": status
        ]), to: root.appendingPathComponent("vscode-setup-result.json"))
    }

    func cleanup() {
        models.forEach { $0.stop() }
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
enum OnboardingChecks {
    static func lifecycle() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        model.settingsTab = .privacy
        model.resumeOnboarding()
        try NotchChecks.require(model.setupStep == .welcome && !model.onboardingComplete, "First run starts at welcome")
        try NotchChecks.require(!model.finishOnboarding() && model.onboardingMessage != nil, "Cannot finish before taking the steps")
        model.advanceOnboarding()
        model.advanceOnboarding()
        try NotchChecks.require(model.setupStep == .connections && model.onboardingMessage != nil,
                                "No client cannot advance, including a direct model call")
        fixture.defaults.set(true, forKey: "accountConnectionEnabled")
        try NotchChecks.require(!model.hasOnboardingConnection, "Account quota alone is not a local connection")
        fixture.defaults.set(false, forKey: "accountConnectionEnabled")
        model.selectOnboardingClient(.cli)
        model.pauseOnboarding()
        try NotchChecks.require(!model.showOnboarding && !model.onboardingComplete, "Pause must not finish onboarding")
        try NotchChecks.require(!FileManager.default.fileExists(atPath: fixture.root.path), "Browsing setup must not install or collect")
        let resumed = fixture.model()
        resumed.resumeOnboarding()
        try NotchChecks.require(resumed.setupStep == .connections && resumed.onboarding.activeClient == .cli
                                && resumed.onboarding.clients == [.cli], "Restore the unfinished page and client")
        try NotchChecks.require(resumed.install(.cli), "Fixture CLI installation failed")
        try NotchChecks.require(resumed.hasOnboardingConnection && resumed.lastActivityEvent.isEmpty,
                                "Successful CLI configuration qualifies before any activity")
        resumed.advanceOnboarding()
        try NotchChecks.require(resumed.setupStep == .preferences && !resumed.onboardingComplete,
                                "Preferences are still part of the unfinished workflow")
        resumed.pauseOnboarding()
        let preferences = fixture.model()
        preferences.resumeOnboarding()
        try NotchChecks.require(preferences.setupStep == .preferences && preferences.hasOnboardingConnection,
                                "A relaunch retains and rechecks configuration")
        preferences.backOnboarding()
        preferences.selectOnboardingClient(.vscode)
        preferences.advanceOnboarding()
        try NotchChecks.require(preferences.setupStep == .preferences,
                                "An unconfigured second client must not block an already chosen configured client")
        try NotchChecks.require(preferences.finishOnboarding() && preferences.finishOnboarding(),
                                "Completion should be guarded and idempotent")
        try NotchChecks.require(preferences.onboardingComplete && preferences.showOnboarding && preferences.setupStep == .complete,
                                "Persist completion without dismissing the welcome result")
        try assertConsentUnchanged(preferences)
        preferences.dismissCompletedOnboarding()
        try NotchChecks.require(!preferences.showOnboarding && preferences.settingsTab == .usage,
                                "Start using Tokenotch leaves first-run setup for Usage")
        preferences.settingsTab = .privacy
        preferences.reviewOnboarding()
        try NotchChecks.require(preferences.onboardingComplete && preferences.setupStep == .welcome,
                                "Review must not revoke existing completion")
        preferences.advanceOnboarding()
        preferences.advanceOnboarding()
        preferences.finishOnboarding()
        preferences.dismissCompletedOnboarding()
        try NotchChecks.require(preferences.settingsTab == .privacy, "Review returns to the prior Settings destination")
        try NotchChecks.require(model.settingsTab == .privacy && fixture.opened.isEmpty,
                                "Browsing and CLI configuration must not route to another tab or open an external app")
    }

    static func eligibilityAndRecovery() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        model.resumeOnboarding()
        model.advanceOnboarding()
        model.selectOnboardingClient(.vscode)
        try NotchChecks.require(model.install(.vscode) && !model.hasOnboardingConnection,
                                "The VS Code helper alone cannot count as configured")
        model.configureVSCode(metrics: false)
        guard let first = model.vscode.pendingRequest else { throw NotchCheckFailure.failed("Missing VS Code request") }
        model.configureVSCode(metrics: false)
        try NotchChecks.require(model.vscode.pendingRequest?.nonce == first.nonce && !model.hasOnboardingConnection,
                                "Repeated setup cannot replace pending approval or satisfy the gate")
        try fixture.result(model, status: "configured", nonce: String(repeating: "0", count: 64))
        model.vscode.tick()
        try NotchChecks.require(!model.hasOnboardingConnection, "Unrelated results cannot approve setup")
        try fixture.result(model, status: "cancelled")
        model.vscode.tick()
        try NotchChecks.require(!model.hasOnboardingConnection && model.vscode.phase == .cancelled,
                                "Cancellation cannot approve setup")
        model.configureVSCode(metrics: false)
        model.vscode.tick(now: Date().addingTimeInterval(601))
        try NotchChecks.require(model.vscode.phase == .failed && model.vscode.error?.contains("expired") == true,
                                "An expired approval is actionable and retryable")
        model.configureVSCode(metrics: false)
        let abandonedNonce = model.vscode.pendingRequest?.nonce
        model.pauseOnboarding()
        model.stop()
        let restored = fixture.model()
        restored.resumeOnboarding()
        try NotchChecks.require(restored.vscode.phase == .failed && restored.vscode.pendingRequest == nil
                                && restored.onboarding.activeClient == .vscode && !restored.hasOnboardingConnection,
                                "Restart restores the page but does not replay an interrupted approval")
        restored.configureVSCode(metrics: false)
        try fixture.result(restored, status: "configured", nonce: abandonedNonce)
        restored.vscode.tick()
        try NotchChecks.require(!restored.hasOnboardingConnection, "A pre-restart approval cannot complete a fresh request")
        try fixture.result(restored, status: "blocked")
        restored.vscode.tick()
        try NotchChecks.require(!restored.hasOnboardingConnection, "Blocked configuration cannot count as ready")
        restored.configureVSCode(metrics: false)
        restored.pauseOnboarding()
        try fixture.result(restored, status: "configured")
        // The controller must consume approval without any Settings view or manual tick.
        try NotchChecks.waitUntil { restored.vscode.activityConfigured }
        try NotchChecks.require(!restored.showOnboarding && restored.hasOnboardingConnection,
                                "Approval keeps updating while setup is paused")
        restored.resumeOnboarding()
        try NotchChecks.require(restored.setupStep == .connections && restored.lastActivityEvent.isEmpty,
                                "Approval updates status without advancing pages or inventing activity")
        restored.advanceOnboarding()
        try NotchChecks.require(restored.finishOnboarding(), "VS Code alone can finish after configuration")
        let approved = fixture.model()
        approved.reviewOnboarding()
        approved.advanceOnboarding()
        try NotchChecks.require(approved.hasOnboardingConnection && approved.vscode.phase == .configured,
                                "Approved configuration survives restart")
        fixture.defaults.forceHooks = true
        fixture.defaults.set(true, forKey: "DisableHooks")
        approved.advanceOnboarding()
        try NotchChecks.require(approved.setupStep == .connections && !approved.hasOnboardingConnection
                                && approved.onboardingMessage?.contains("organization") == true,
                                "Managed policy supersedes previous configuration")
        fixture.defaults.forceHooks = false
        approved.advanceOnboarding()
        approved.uninstall(.vscode)
        try NotchChecks.require(!approved.finishOnboarding(), "Disconnect before Finish must invalidate eligibility")
        try fixture.result(approved, status: "removed")
        approved.vscode.tick()
        try NotchChecks.require(!approved.vscode.removingActivity, "Confirmed removal clears pending removal state")
    }

    static func failedInstallAndMigration() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        model.resumeOnboarding()
        model.advanceOnboarding()
        model.selectOnboardingClient(.cli)
        let helper = fixture.bundle.appendingPathComponent("Contents/Helpers/TokenotchHook")
        try FileManager.default.removeItem(at: helper)
        try NotchChecks.require(!model.install(.cli) && model.connectionSetupErrors[.cli] != nil
                                && !model.hasOnboardingConnection, "Missing bundled files must be explicit failures")
        try Data("Fixture helper".utf8).write(to: helper)
        try NotchChecks.require(model.install(.cli), "Installation must remain retryable")
        let extensionFile = fixture.installation.cliHome.appendingPathComponent("extensions/tokenotch-token-usage/extension.mjs")
        try FileManager.default.removeItem(at: extensionFile)
        model.advanceOnboarding()
        try NotchChecks.require(model.setupStep == .connections && model.connectionSetupErrors[.cli] != nil,
                                "Recheck missing setup files before advancing")
        try NotchChecks.require(model.install(.cli), "Repair must restore missing owned files")
        try PrivateFiles.write(Data("User-edited hook".utf8), to: fixture.installation.hookURL(.cli))
        try NotchChecks.require(!model.install(.cli) && !model.hasOnboardingConnection,
                                "An ownership conflict must not be presented as success")
        model.selectOnboardingClient(.vscode)
        model.configureVSCode(metrics: false)
        try fixture.result(model, status: "configured")
        model.vscode.tick()
        model.advanceOnboarding()
        try NotchChecks.require(model.finishOnboarding() && model.connectionSetupErrors[.cli] != nil,
                                "A failed client must stay visible without blocking a successful alternative")
        for (legacy, expected) in [(-1, OnboardingStep.welcome), (0, .welcome), (1, .connections), (2, .preferences), (99, .preferences)] {
            fixture.defaults.removeObject(forKey: "onboardingStep.v2")
            fixture.defaults.set(legacy, forKey: "onboardingStep.v1")
            fixture.defaults.set(false, forKey: "onboardingComplete.v1")
            try NotchChecks.require(fixture.model().setupStep == expected, "Legacy page migration failed")
        }
        fixture.defaults.set("complete", forKey: "onboardingStep.v2")
        try NotchChecks.require(fixture.model().setupStep == .connections, "An incomplete install cannot restore a completed page")
        fixture.defaults.set(true, forKey: "onboardingComplete.v1")
        let completed = fixture.model()
        try NotchChecks.require(completed.onboardingComplete && !completed.showOnboarding,
                                "Existing completed installs must not be automatically re-enrolled")
    }

    private static func assertConsentUnchanged(_ model: TokenotchModel) throws {
        try NotchChecks.require(!model.options.notifications.enabled && !model.options.notifications.sound
                                && !model.options.notifications.expandNotch && !model.options.healthEnabled
                                && !model.history.enabled && !model.timeline.enabled && !model.attention.saving
                                && !model.vscode.enabled && !model.accountConnectionEnabled,
                                "Onboarding must preserve separate opt-in defaults")
    }

    private static func text(in image: NSBitmapImageRep) throws -> [VNRecognizedTextObservation] {
        guard let cgImage = image.cgImage else { throw NotchCheckFailure.failed("Missing onboarding image") }
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return request.results ?? []
    }

    static func render(directory: URL? = nil) throws {
        let fixture = try OnboardingFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        model.resumeOnboarding()
        for step in OnboardingStep.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let image = try NotchChecks.hostedImage(OnboardingView(model: model).environment(\.colorScheme, scheme),
                                                      size: CGSize(width: 620, height: 540))
                try NotchChecks.save(image, name: "onboarding-\(step.rawValue)-\(scheme)", directory: directory)
                let content = try text(in: image).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                let action: String
                switch step {
                case .welcome: action = "Get started"
                case .connections: action = "Continue"
                case .preferences: action = "Finish setup"
                case .complete: action = "Start using Tokenotch"
                }
                try NotchChecks.require(content.contains(action), "Primary action must remain visible on \(step)")
                if step == .connections {
                    try NotchChecks.require(content.contains("Copilot CLI") && content.contains("Visual Studio Code"),
                                            "Both client choices must be visible")
                }
                if step == .complete {
                    try NotchChecks.require(content.contains("Your setup is complete") && content.contains("Waiting for first activity"),
                                            "Welcome must distinguish configuration from delivery")
                }
                if step == .preferences {
                    try NotchChecks.require(content.contains("Allow notifications") && content.contains("Save usage history"),
                                            "Basic opt-in choices must be available inline")
                }
            }
            if step == .connections {
                model.selectOnboardingClient(.cli)
                try NotchChecks.require(model.install(.cli), "Render fixture installation")
            }
            if step != .complete { model.advanceOnboarding() }
        }
        try assertConsentUnchanged(model)
    }

    static func connectionStates(directory: URL? = nil) throws {
        let fixture = try OnboardingFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        model.resumeOnboarding()
        model.advanceOnboarding()

        func capture(_ name: String, contains expected: String) throws {
            for scheme in [ColorScheme.light, .dark] {
                let image = try NotchChecks.hostedImage(OnboardingView(model: model).environment(\.colorScheme, scheme),
                                                      size: CGSize(width: 620, height: 540))
                try NotchChecks.save(image, name: "onboarding-\(name)-\(scheme)", directory: directory)
                let content = try text(in: image).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                try NotchChecks.require(content.contains(expected), "Missing inline state: \(name)")
                try NotchChecks.require(content.contains(model.setupStep == .complete ? "Start using Tokenotch" : "Continue"),
                                        "State \(name) displaced the fixed action footer")
            }
        }

        model.selectOnboardingClient(.cli)
        try capture("cli-choices", contains: "Connect Copilot CLI")
        try NotchChecks.require(model.install(.cli), "Configured-client render fixture")
        try capture("cli-configured", contains: "Waiting for first activity")
        model.selectOnboardingClient(.vscode)
        try capture("vscode-choices", contains: "Install setup extension")
        model.configureVSCode(metrics: false)
        try capture("vscode-approval", contains: "Approve the Tokenotch")
        try fixture.result(model, status: "blocked")
        model.vscode.tick()
        try capture("vscode-blocked", contains: "VS Code blocked")
        model.advanceOnboarding()
        try NotchChecks.require(model.finishOnboarding(), "A blocked second client must not prevent the result")
        try capture("partial-result", contains: "VS Code blocked")
        try assertConsentUnchanged(model)
    }

    static func interaction() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        model.settingsTab = .privacy
        model.resumeOnboarding()
        let panel = NotchPanel(contentRect: CGRect(x: 150, y: 150, width: 620, height: 540))
        panel.acceptsKeyboardFocus = true
        let host = NSHostingView(rootView: OnboardingView(model: model))
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }

        func press(_ title: String) throws {
            func find() throws -> VNRecognizedTextObservation? {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let image = try NotchChecks.capture(host)
                return try text(in: image).first { $0.topCandidates(1).first?.string == title }
            }
            var found = try find()
            if found == nil {
                func scrollView(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
                }
                if let scroll = scrollView(in: host), let document = scroll.documentView {
                    let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, bottom)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    found = try find()
                }
            }
            guard let found else {
                throw NotchCheckFailure.failed("Onboarding action not visible: \(title)")
            }
            let bounds = found.boundingBox
            let point = CGPoint(x: bounds.midX * host.bounds.width,
                                y: (host.isFlipped ? 1 - bounds.midY : bounds.midY) * host.bounds.height)
            try NotchChecks.click(panel, at: host.convert(point, to: nil))
        }

        try press("Get started")
        try press("Copilot CLI")
        try NotchChecks.require(model.onboarding.activeClient == .cli && model.settingsTab == .privacy && model.showOnboarding,
                                "Selecting a connection must stay inside onboarding")
        try press("Pause setup")
        try NotchChecks.require(!model.showOnboarding && !model.onboardingComplete, "Pause action must not complete setup")
        model.resumeOnboarding()
        try NotchChecks.require(model.onboarding.activeClient == .cli, "Pause must retain the selected connection")
        try press("Connect Copilot CLI")
        try NotchChecks.require(model.hasOnboardingConnection && model.showOnboarding && model.settingsTab == .privacy,
                                "The actual Connect action must configure the client without leaving onboarding")
        try press("Continue")
        try press("Back")
        try NotchChecks.require(model.setupStep == .connections && model.showOnboarding && model.settingsTab == .privacy,
                                "Back must stay in the wizard")
        try press("Continue")
        try press("Finish setup")
        try NotchChecks.require(model.setupStep == .complete && model.showOnboarding, "Finish must show a result before closing")
        try press("Start using Tokenotch")
        try NotchChecks.require(!model.showOnboarding && model.settingsTab == .usage, "The final action must open Tokenotch")
        try assertConsentUnchanged(model)
    }
}
