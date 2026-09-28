import Foundation

public struct HookInstallation {
    public let root: URL
    public let cliHome: URL
    public init(root: URL = PrivateFiles.root,
                cliHome: URL = ProcessInfo.processInfo.environment["COPILOT_HOME"]
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")) {
        self.root = root
        self.cliHome = cliHome
    }

    public func hookURL(_ client: Client) -> URL {
        let directory = client == .cli ? cliHome.appendingPathComponent("hooks") : root.appendingPathComponent("vscode-hooks")
        return directory.appendingPathComponent("tokenotch-v1.json")
    }

    public func configuration(_ client: Client, helper: URL) throws -> Data {
        let names = client == .cli
            ? ["sessionStart", "userPromptSubmitted", "agentStop", "sessionEnd", "notification", "errorOccurred"]
            : ["SessionStart", "UserPromptSubmit", "Stop"]
        let hooks: [String: [[String: Any]]] = Dictionary(uniqueKeysWithValues: names.map { name in
            if client == .cli {
                var entry: [String: Any] = ["type": "command", "exec": helper.path,
                                           "args": ["cli", name], "timeoutSec": 2]
                if name == "notification" { entry["matcher"] = "permission_prompt|elicitation_dialog" }
                return (name, [entry])
            }
            let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return (name, [["type": "command", "osx": "\(quoted) vscode \(name)", "timeout": 2]])
        })
        return try JSONSerialization.data(withJSONObject: ["version": 1, "hooks": hooks],
                                           options: [.prettyPrinted, .sortedKeys])
    }

    public func install(_ client: Client, bundledHelper: URL, usageExtension: Data? = nil) throws {
        try PrivateFiles.directory(root)
        let hook = hookURL(client)
        // Do not chmod existing client directories or follow symlinked configuration roots.
        if client == .cli {
            try clientDirectory(cliHome)
            try clientDirectory(cliHome.appendingPathComponent("hooks"))
        } else {
            try PrivateFiles.directory(hook.deletingLastPathComponent())
        }
        let receipt = root.appendingPathComponent("\(client.rawValue).receipt")
        if let existing = try PrivateFiles.read(hook) {
            guard let original = try PrivateFiles.read(receipt), original == existing else { throw TokenotchError.ownership }
        }
        let helper = root.appendingPathComponent("TokenotchHook")
        let binary = try Data(contentsOf: bundledHelper)
        try PrivateFiles.write(binary, to: helper)
        guard chmod(helper.path, 0o700) == 0 else { throw TokenotchError.storage }
        let config = try configuration(client, helper: helper)
        // A receipt before a hook allows safe recovery from an interrupted install.
        try PrivateFiles.write(config, to: receipt)
        try writeHook(config, to: hook)
        if client == .cli, let usageExtension {
            let extensions = cliHome.appendingPathComponent("extensions")
            try clientDirectory(extensions)
            let directory = extensions.appendingPathComponent("tokenotch-token-usage")
            try PrivateFiles.directory(directory)
            let file = directory.appendingPathComponent("extension.mjs")
            let receipt = root.appendingPathComponent("cli-extension.receipt")
            if let existing = try PrivateFiles.read(file), existing != (try PrivateFiles.read(receipt)) {
                throw TokenotchError.ownership
            }
            try PrivateFiles.write(usageExtension, to: receipt)
            try PrivateFiles.write(usageExtension, to: file)
        }
        try PrivateFiles.write(Data(UUID().uuidString.utf8),
                               to: root.appendingPathComponent("\(client.rawValue).registration"))
    }

    public func isInstalled(_ client: Client, expectedUsageExtension: Data? = nil) throws -> Bool {
        guard try PrivateFiles.read(root.appendingPathComponent("\(client.rawValue).registration")) != nil else { return false }
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("TokenotchHook").path),
              let receipt = try PrivateFiles.read(root.appendingPathComponent("\(client.rawValue).receipt")),
              let hook = try PrivateFiles.read(hookURL(client)) else { return false }
        guard hook == receipt else { throw TokenotchError.ownership }
        if client == .cli {
            guard let receipt = try PrivateFiles.read(root.appendingPathComponent("cli-extension.receipt")),
                  let content = try PrivateFiles.read(cliHome.appendingPathComponent("extensions/tokenotch-token-usage/extension.mjs"))
            else { return false }
            guard content == receipt else { throw TokenotchError.ownership }
            if let expectedUsageExtension, content != expectedUsageExtension { return false }
        }
        return true
    }

    public func uninstall(_ client: Client) throws {
        try PrivateFiles.directory(root)
        let hook = hookURL(client)
        let receipt = root.appendingPathComponent("\(client.rawValue).receipt")
        // Withdraw bridge consent even if someone changed the hook.
        let registration = root.appendingPathComponent("\(client.rawValue).registration")
        if try PrivateFiles.read(registration) != nil {
            guard unlink(registration.path) == 0 else { throw TokenotchError.storage }
        }
        let parent = hook.deletingLastPathComponent()
        guard parent.path == parent.resolvingSymlinksInPath().path else { throw TokenotchError.unsafePath }
        if let contents = try PrivateFiles.read(hook) {
            guard contents == (try PrivateFiles.read(receipt)) else { throw TokenotchError.ownership }
            guard unlink(hook.path) == 0 else { throw TokenotchError.storage }
        }
        if try PrivateFiles.read(receipt) != nil {
            guard unlink(receipt.path) == 0 else { throw TokenotchError.storage }
        }
        if client == .cli {
            let receipt = root.appendingPathComponent("cli-extension.receipt")
            if let original = try PrivateFiles.read(receipt) {
                let file = cliHome.appendingPathComponent("extensions/tokenotch-token-usage/extension.mjs")
                let parent = file.deletingLastPathComponent()
                guard parent.path == parent.resolvingSymlinksInPath().path else { throw TokenotchError.unsafePath }
                if let existing = try PrivateFiles.read(file) {
                    guard existing == original else { throw TokenotchError.ownership }
                    guard unlink(file.path) == 0 else { throw TokenotchError.storage }
                }
                guard unlink(receipt.path) == 0 else { throw TokenotchError.storage }
            }
        }
    }

    private func clientDirectory(_ url: URL) throws {
        guard url.path == url.resolvingSymlinksInPath().path else { throw TokenotchError.unsafePath }
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw TokenotchError.unsafePath }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else { throw TokenotchError.unsafePath }
    }

    private func writeHook(_ data: Data, to url: URL) throws {
        // Existing client hook directories need not be private; the file must be.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tokenotch-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TokenotchError.storage }
        defer { close(fd); unlink(temporary.path) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard count == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw TokenotchError.storage
        }
    }
}
