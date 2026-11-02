import Darwin
import Foundation

public enum ClaudeAccountError: String, Error {
    case missingCLI = "Choose an installed Claude Code CLI executable before connecting."
    case invalidResponse = "The Claude CLI returned an unsupported authentication status."
    case failed = "Could not check Claude sign-in. Retry using the official Claude Code CLI."
    case timeout = "The Claude CLI authentication check timed out."
    case configuration = "Choose an absolute local Claude configuration directory."
    case configurationChanged = "The Claude CLI reported a different configuration directory. Review its account connection."
}

public struct ClaudeAuthenticationStatus: Sendable, Equatable {
    public enum Method: String, Decodable, Sendable {
        case none, claudeAI = "claude.ai", oauthToken = "oauth_token"
        case apiKey = "api_key", apiKeyHelper = "api_key_helper", thirdParty = "third_party"
    }
    public let signedIn: Bool
    public let method: Method
    public var title: String {
        guard signedIn else { return "Not signed in to Claude" }
        switch method {
        case .claudeAI, .oauthToken: return "Signed in to Claude"
        case .apiKey, .apiKeyHelper: return "API authentication; subscription quota is not verified"
        case .thirdParty: return "Third-party authentication; subscription quota is not verified"
        case .none: return "Not signed in to Claude"
        }
    }

    public static func parse(_ data: Data, exitCode: Int32, expectedRoot: URL? = nil) throws -> Self {
        struct Response: Decodable { let loggedIn: Bool; let authMethod: Method; let configDirectory: String? }
        guard data.count <= 65_536 else { throw ClaudeAccountError.invalidResponse }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ClaudeAccountError.invalidResponse }
        guard exitCode == (response.loggedIn ? 0 : 1),
              !response.loggedIn || response.authMethod != .none else { throw ClaudeAccountError.invalidResponse }
        if let expectedRoot, let reported = response.configDirectory {
            guard reported.hasPrefix("/"),
                  URL(fileURLWithPath: reported).standardizedFileURL.resolvingSymlinksInPath() ==
                    expectedRoot.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ClaudeAccountError.configurationChanged
            }
        }
        return Self(signedIn: response.loggedIn, method: response.authMethod)
    }
}

public final class ClaudeAccountRuntime {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let executable: URL
    private let configurationRoot: URL

    public init(executable: URL, configurationRoot: URL) {
        self.executable = executable
        self.configurationRoot = configurationRoot
    }

    public static func detectExecutable() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    public static func loginScript(executable: URL, configurationRoot: URL) throws -> Data {
        try validate(executable: executable, configurationRoot: configurationRoot)
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Data("""
        #!/bin/sh
        cd \(quote(home)) || exit 1
        exec /usr/bin/env -i \(quote("HOME=\(home)")) 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' 'TERM=dumb' \(quote("CLAUDE_CONFIG_DIR=\(configurationRoot.path)")) \(quote(executable.path)) auth login

        """.utf8)
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    public func status() throws -> ClaudeAuthenticationStatus {
        try Self.validate(executable: executable, configurationRoot: configurationRoot)
        let output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["auth", "status"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": configurationRoot.path, "TERM": "dumb"
        ]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw ClaudeAccountError.failed }
        defer { finish(child) }
        var data = Data()
        var ended = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while child.isRunning || !ended {
            lock.lock()
            let stopped = cancelled
            lock.unlock()
            if stopped { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ClaudeAccountError.timeout }
            if ended { Thread.sleep(forTimeInterval: 0.01); continue }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw ClaudeAccountError.failed }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
            guard count >= 0 else { throw ClaudeAccountError.failed }
            if count == 0 { ended = true; continue }
            guard data.count + count <= 65_536 else { throw ClaudeAccountError.invalidResponse }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try ClaudeAuthenticationStatus.parse(data, exitCode: child.terminationStatus, expectedRoot: configurationRoot)
    }

    private static func validate(executable: URL, configurationRoot: URL) throws {
        guard configurationRoot.isFileURL, configurationRoot.path.hasPrefix("/") else { throw ClaudeAccountError.configuration }
        var directory: ObjCBool = false
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: executable.path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw ClaudeAccountError.missingCLI }
    }

    private func finish(_ child: Process) {
        if child.isRunning { child.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        lock.lock()
        process = nil
        lock.unlock()
    }
}
