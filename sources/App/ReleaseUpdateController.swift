import AppKit
import Combine
import TokenotchCore

@MainActor
final class ReleaseUpdateController: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var message = "Checks run only when you choose Check for Updates."
    @Published private(set) var available: ReleaseInfo?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let currentVersion: String
    private let latest: () async throws -> ReleaseInfo

    init(currentVersion: String = AppVersion.short,
         latest: @escaping () async throws -> ReleaseInfo = { try await ReleaseCheck.latest() }) {
        self.currentVersion = currentVersion
        self.latest = latest
    }

    func check() {
        guard !checking else { return }
        checking = true
        available = nil
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
                } else {
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
