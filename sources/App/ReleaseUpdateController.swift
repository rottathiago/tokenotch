import AppKit
import Combine
import TokenotchCore

@MainActor
final class ReleaseUpdateController: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var message = "Checks run only when you choose Check for Updates."
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var automaticChecks: Bool
    var onAvailable: ((ReleaseInfo) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let defaults: UserDefaults
    private let currentVersion: String
    private let latest: () async throws -> ReleaseInfo

    init(currentVersion: String = AppVersion.short,
         defaults: UserDefaults = .standard,
         latest: @escaping () async throws -> ReleaseInfo = { try await ReleaseCheck.latest() }) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.latest = latest
        automaticChecks = defaults.bool(forKey: "automaticUpdateChecks.v1")
        if automaticChecks { message = "Checks run daily while Tokenotch is open. Downloads and installation stay manual." }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        automaticChecks = enabled
        defaults.set(enabled, forKey: "automaticUpdateChecks.v1")
        if enabled {
            poll()
        } else {
            stop()
            message = "Checks run only when you choose Check for Updates."
        }
    }

    func poll(now: Date = Date()) {
        guard automaticChecks, !checking else { return }
        if let last = defaults.object(forKey: "lastUpdateCheck.v1") as? Date,
           now >= last, now.timeIntervalSince(last) < 86_400 { return }
        performCheck(automatically: true, now: now)
    }

    func check() {
        performCheck(automatically: false, now: Date())
    }

    private func performCheck(automatically: Bool, now: Date) {
        guard !checking else { return }
        checking = true
        defaults.set(now, forKey: "lastUpdateCheck.v1")
        message = "Checking the official GitHub releases..."
        let id = UUID()
        generation = id
        task = Task {
            defer {
                if generation == id { checking = false; task = nil }
            }
            do {
                let release = try await latest()
                guard generation == id, !Task.isCancelled else { return }
                guard let current = ReleaseVersion(currentVersion) else { throw ReleaseCheckError.invalid }
                if release.version > current {
                    available = release
                    message = "\(release.tag) is available. Download and install it from the official release page."
                    if automatically, automaticChecks,
                       defaults.string(forKey: "notifiedUpdateVersion.v1").flatMap(ReleaseVersion.init) != release.version {
                        defaults.set(release.tag, forKey: "notifiedUpdateVersion.v1")
                        onAvailable?(release)
                    }
                } else {
                    available = nil
                    message = "You have the latest stable version or a newer build."
                }
            } catch is CancellationError {
                if generation == id { message = "Release check cancelled." }
            } catch {
                guard generation == id else { return }
                message = (error as? ReleaseCheckError)?.rawValue ?? ReleaseCheckError.unavailable.rawValue
            }
        }
    }

    func openRelease() {
        guard let available else { return }
        if !NSWorkspace.shared.open(available.url) {
            message = "Could not open the official release page. Check your default browser."
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        checking = false
    }
}
