import AppKit
import Combine
import Foundation
import TokenotchCore

@MainActor
final class ClaudeAccountController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var authentication: ClaudeAuthenticationStatus?
    @Published private(set) var status = "Claude account checks are off"
    @Published var executable: String {
        didSet {
            if executable != oldValue { disconnect(); defaults.set(executable, forKey: "claudeExecutable") }
        }
    }
    private let defaults: UserDefaults
    private let root: URL
    private let openLogin: (URL) -> Bool
    private var task: Task<Void, Never>?
    private var runtime: ClaudeAccountRuntime?
    private var generation = UUID()
    private var nextCheck = Date.distantPast
    private var launcher: URL?
    private var managed: Bool {
        defaults.objectIsForced(forKey: "DisableAccountConnection") && defaults.bool(forKey: "DisableAccountConnection")
    }

    init(defaults: UserDefaults, root: URL, openLogin: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.root = root
        self.openLogin = openLogin
        enabled = defaults.bool(forKey: "claudeAccountEnabled")
        executable = defaults.string(forKey: "claudeExecutable") ?? ClaudeAccountRuntime.detectExecutable()
    }

    func signIn(configurationRoot: URL) {
        guard approve(configurationRoot) else { return }
        do {
            let data = try ClaudeAccountRuntime.loginScript(executable: URL(fileURLWithPath: executable),
                                                          configurationRoot: configurationRoot)
            let file = root.appendingPathComponent("claude-login-\(UUID().uuidString).command")
            try PrivateFiles.write(data, to: file)
            launcher = file
            guard chmod(file.path, 0o700) == 0, openLogin(file) else {
                status = "Could not open Claude sign-in in Terminal. Retry or run claude auth login yourself."
                cleanupLauncher()
                return
            }
            status = "Finish Claude sign-in in Terminal and your browser, then check sign-in."
            nextCheck = Date().addingTimeInterval(60)
        } catch { status = (error as? ClaudeAccountError)?.rawValue ?? "Could not prepare Claude sign-in; no credentials were read." }
    }

    func connect(configurationRoot: URL) {
        guard approve(configurationRoot) else { return }
        nextCheck = .distantPast
        refresh(configurationRoot: configurationRoot)
    }

    func refresh(configurationRoot: URL) {
        guard !managed else { stop(); status = "Claude account checks are disabled by managed policy"; return }
        guard enabled, !busy, Date() >= nextCheck else { return }
        guard defaults.string(forKey: "claudeAccountConfigurationRoot") == configurationRoot.standardizedFileURL.path else {
            stop()
            authentication = nil
            status = "The selected Claude configuration changed. Reconnect its account explicitly."
            return
        }
        let request = generation
        let worker = ClaudeAccountRuntime(executable: URL(fileURLWithPath: executable), configurationRoot: configurationRoot)
        runtime = worker
        busy = true
        nextCheck = Date().addingTimeInterval(60)
        status = "Checking Claude CLI sign-in..."
        task = Task {
            do {
                let result = try await Task.detached { try worker.status() }.value
                guard generation == request else { return }
                authentication = result
                status = result.title
                if result.signedIn { cleanupLauncher() }
            } catch {
                guard generation == request else { return }
                authentication = nil
                status = (error as? ClaudeAccountError)?.rawValue ?? ClaudeAccountError.failed.rawValue
            }
            guard generation == request else { return }
            busy = false
            runtime = nil
            task = nil
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        runtime?.cancel()
        task = nil
        runtime = nil
        busy = false
        cleanupLauncher()
    }

    func disconnect() {
        status = "Account checks stopped; your Claude CLI login is unchanged"
        stop()
        enabled = false
        defaults.set(false, forKey: "claudeAccountEnabled")
        authentication = nil
    }

    private func approve(_ configurationRoot: URL) -> Bool {
        guard !managed else { status = "Claude account checks are disabled by managed policy"; return false }
        guard executable.hasPrefix("/") else { status = ClaudeAccountError.missingCLI.rawValue; return false }
        stop()
        guard launcher == nil else { return false }
        authentication = nil
        enabled = true
        defaults.set(true, forKey: "claudeAccountEnabled")
        defaults.set(configurationRoot.standardizedFileURL.path, forKey: "claudeAccountConfigurationRoot")
        return true
    }

    private func cleanupLauncher() {
        guard let launcher else { return }
        do {
            if FileManager.default.fileExists(atPath: launcher.path) { try FileManager.default.removeItem(at: launcher) }
            self.launcher = nil
        } catch { status += " Temporary sign-in launcher cleanup failed." }
    }
}
