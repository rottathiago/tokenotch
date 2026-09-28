import Darwin
import Foundation

public final class CopilotRuntime {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public let executable: URL
    public let home: URL

    public init(executable: URL, home: URL) {
        self.executable = executable
        self.home = home
    }
    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    public func signIn() throws {
        let child = try start(arguments: ["--no-auto-update", "--log-level", "none", "login", "--web-flow"])
        defer { finish(child.process) }
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while child.process.isRunning {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CopilotConnectionError.timeout }
            Thread.sleep(forTimeInterval: 0.1)
            // Login output is intentionally discarded; credentials and callback URLs never enter app logs.
        }
        guard child.process.terminationStatus == 0 else { throw CopilotConnectionError.loginFailed }
    }

    public func snapshot() throws -> CopilotAccountSnapshot {
        // Headless mode reuses saved credentials without browser login.
        // --no-auto-login would prevent loading the account authorized by signIn().
        let args = ["--headless", "--stdio", "--no-auto-update", "--log-level", "none"]
        let child = try start(arguments: args, rpc: true)
        defer { finish(child.process) }
        var frames = RPCFrames()
        let status = try request("status.get", id: 1, child: child, frames: &frames)
        struct Status: Decodable { let version: String; let protocolVersion: Int }
        let version = try JSONDecoder().decode(Status.self, from: status)
        guard version.protocolVersion == 2 || version.protocolVersion == 3 else {
            throw CopilotConnectionError.incompatible
        }
        let identity = try request("auth.getStatus", id: 2, child: child, frames: &frames)
        let auth = try JSONDecoder().decode(CopilotIdentity.self, from: identity)
        guard auth.isAuthenticated else { throw CopilotConnectionError.signIn }
        let quota = try request("account.getQuota", id: 3, child: child, frames: &frames)
        let confirmed = try request("auth.getStatus", id: 4, child: child, frames: &frames)
        guard try JSONDecoder().decode(CopilotIdentity.self, from: confirmed) == auth else {
            throw CopilotConnectionError.signIn
        }
        return try CopilotAccountSnapshot.parse(identity: identity, quota: quota, version: version.version)
    }

    private struct Child {
        let process: Process
        let input: Pipe
        let output: Pipe
    }

    private func start(arguments: [String], rpc: Bool = false) throws -> Child {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CopilotConnectionError.missingCLI }
        try PrivateFiles.directory(home)
        let gh = home.appendingPathComponent("gh-disabled")
        try PrivateFiles.directory(gh)
        let input = Pipe()
        let output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = home
        // No ambient tokens, provider endpoints, telemetry exporters or CLI configuration are inherited.
        child.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "COPILOT_HOME": home.path,
            "GH_CONFIG_DIR": gh.path,
            "TERM": "dumb"
        ]
        child.standardInput = rpc ? input : FileHandle.nullDevice
        child.standardOutput = rpc ? output : FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try child.run()
        process = child
        return Child(process: child, input: input, output: output)
    }

    private func finish(_ child: Process) {
        if child.isRunning { child.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        lock.lock()
        process = nil
        lock.unlock()
    }

    private func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }

    private func request(_ method: String, id: Int, child: Child, frames: inout RPCFrames) throws -> Data {
        try child.input.fileHandleForWriting.write(contentsOf: RPCFrames.encode(id: id, method: method))
        let fd = child.output.fileHandleForReading.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkCancellation()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw CopilotConnectionError.failed }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw CopilotConnectionError.failed }
            for frame in try frames.append(Data(buffer.prefix(count))) {
                guard let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                    throw CopilotConnectionError.invalidResponse
                }
                guard message["id"] as? Int == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    let text = (error["message"] as? String ?? "").lowercased()
                    if error["code"] as? Int == -32601 { throw CopilotConnectionError.incompatible }
                    if text.contains("429") || text.contains("rate limit") { throw CopilotConnectionError.rateLimited }
                    if text.contains("403") || text.contains("forbidden") { throw CopilotConnectionError.forbidden }
                    if text.contains("401") || text.contains("unauthenticated") { throw CopilotConnectionError.signIn }
                    throw CopilotConnectionError.failed
                }
                guard let result = message["result"], JSONSerialization.isValidJSONObject(result) else {
                    throw CopilotConnectionError.invalidResponse
                }
                return try JSONSerialization.data(withJSONObject: result)
            }
        }
        throw CopilotConnectionError.timeout
    }
}
