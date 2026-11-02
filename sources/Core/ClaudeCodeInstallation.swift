import Darwin
import Foundation

public enum ClaudeSetupError: String, Error, LocalizedError {
    case conflict = "Claude telemetry settings or environment already exist. Review them before connecting; nothing was replaced."
    case policy = "Managed Claude settings may control telemetry. Ask your administrator; Tokenotch will not override them."
    case review = "Check Claude /status for managed telemetry and confirm the selected local configuration root before setup."
    case changed = "Claude settings changed during setup. Review the settings and retry."
    case ownership = "Claude settings no longer match Tokenotch's receipt. Collection is stopped; review or remove the owned settings."
    case interrupted = "Claude setup was interrupted. Retry setup or remove the pending settings."
    case permissions = "Claude settings.json must be readable and writable only by you. Continue setup to review the permission change."
    case unavailable = "The Claude usage receiver is unavailable. Retry the connection."
    case storage = "Claude setup could not finish safely. Existing settings and the recovery receipt were retained."
    case statusLineConflict = "Claude already has a status line. Tokenotch left it unchanged. Remove it in Claude before enabling Tokenotch quota and context reporting."
    public var errorDescription: String? { rawValue }
}

/// Owns only inserted exporter entries, never a copy of the user's settings.
public struct ClaudeCodeInstallation {
    public struct SessionHooks: Codable {
        public var commands: [String: String]
        public let createdContainer: Bool
        public let createdEvents: Set<String>
    }

    public struct Receipt: Codable {
        public let version: Int
        public let configurationRoot: URL
        public let device: UInt64
        public let inode: UInt64
        public let configuration: TelemetryConfiguration
        public var owned: [String: String]
        public let createdEnvironment: Bool
        public var committed: Bool
        public var statusLineCommand: String?
        public var sessionHooks: SessionHooks?
        public var localAttribution: Bool? // Legacy receipt field, retained for exact-owned cleanup.
    }

    public struct PermissionChange: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let configurationRoot: URL
        private let directoryDevice: dev_t
        private let directoryInode: ino_t
        private let fileDevice: dev_t
        private let fileInode: ino_t
        private let mode: mode_t
        private let size: off_t
        private let modifiedSeconds: Int
        private let modifiedNanoseconds: Int

        public var currentPermissions: String { String(format: "%04o", UInt32(mode)) }

        fileprivate init(configurationRoot: URL, directory: stat, file: stat) {
            self.configurationRoot = configurationRoot
            directoryDevice = directory.st_dev; directoryInode = directory.st_ino
            fileDevice = file.st_dev; fileInode = file.st_ino
            mode = file.st_mode & 0o7777; size = file.st_size
            modifiedSeconds = file.st_mtimespec.tv_sec
            modifiedNanoseconds = file.st_mtimespec.tv_nsec
        }

        fileprivate func matches(directory: stat, file: stat) -> Bool {
            directory.st_dev == directoryDevice && directory.st_ino == directoryInode &&
                file.st_dev == fileDevice && file.st_ino == fileInode &&
                file.st_mode & 0o7777 == mode && file.st_size == size &&
                file.st_mtimespec.tv_sec == modifiedSeconds && file.st_mtimespec.tv_nsec == modifiedNanoseconds
        }
    }

    public static var defaultConfigurationRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    public let root: URL
    public init(root: URL = PrivateFiles.root) { self.root = root }
    private var receiptURL: URL { root.appendingPathComponent("claude-settings-receipt.json") }

    public static func environment(_ configuration: TelemetryConfiguration) -> [String: String] {
        [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": configuration.endpoint(.claudeCLI) + "/v1/logs",
            "OTEL_METRICS_EXPORTER": "none", "OTEL_TRACES_EXPORTER": "none",
            "OTEL_METRICS_INCLUDE_ENTRYPOINT": "true", "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
            "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "false", "OTEL_METRICS_INCLUDE_REPOSITORY": "false",
            "OTEL_LOG_USER_PROMPTS": "0", "OTEL_LOG_ASSISTANT_RESPONSES": "0",
            "OTEL_LOG_TOOL_DETAILS": "0", "OTEL_LOG_TOOL_CONTENT": "0",
            "OTEL_LOG_RAW_API_BODIES": "0", "OTEL_LOG_MANAGED_SETTINGS": "0",
            "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "0"
        ]
    }

    private static func approvedEnvironment(_ receipt: Receipt) -> [String: String] {
        var values = environment(receipt.configuration)
        if receipt.localAttribution == true {
            let marker = ActivityEvent.digest("claudeCode:local-installation:\(receipt.configuration.token)")
            values["OTEL_RESOURCE_ATTRIBUTES"] = "tokenotch.local_installation=\(marker)"
        }
        return values
    }

    public static func isTelemetryKey(_ key: String) -> Bool {
        key.hasPrefix("OTEL_") || key.hasPrefix("CLAUDE_CODE_OTEL_") ||
            ["CLAUDE_CODE_ENABLE_TELEMETRY", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA",
             "ENABLE_ENHANCED_TELEMETRY_BETA", "BETA_TRACING_ENDPOINT", "DISABLE_TELEMETRY",
             "DISABLE_NON_ESSENTIAL_MODEL_CALLS"].contains(key)
    }

    public static func hasLocalManagedPolicy() -> Bool {
        for name in ["managed-settings.json", "managed-settings.d"] {
            var info = stat()
            let path = "/Library/Application Support/ClaudeCode/" + name
            if lstat(path, &info) == 0 || errno != ENOENT { return true }
        }
        guard let preferences = UserDefaults(suiteName: "com.anthropic.claudecode") else { return true }
        return preferences.dictionaryRepresentation().keys.contains { preferences.objectIsForced(forKey: $0) }
    }

    public func receipt() throws -> Receipt? {
        try prepareRoot()
        guard let data = try PrivateFiles.read(receiptURL, limit: 32_768) else { return nil }
        let value: Receipt
        do { value = try JSONDecoder().decode(Receipt.self, from: data) }
        catch { throw ClaudeSetupError.ownership }
        try value.configuration.validate()
        let approved = Self.approvedEnvironment(value)
        guard value.version == 1, value.configuration.port > 0,
              value.configurationRoot.isFileURL,
              value.configurationRoot.path.hasPrefix("/"),
              value.statusLineCommand == nil || value.statusLineCommand == statusLineCommand,
              value.sessionHooks.map({ hooks in
                  !hooks.commands.isEmpty && hooks.commands.allSatisfy({ sessionCommands[$0.key] == $0.value }) &&
                      hooks.createdEvents.isSubset(of: Set(sessionCommands.keys))
              }) ?? true,
              value.owned.allSatisfy({ approved[$0.key] == $0.value }) else {
            throw ClaudeSetupError.ownership
        }
        return value
    }

    public static func validateEnvironment(_ environment: [String: String]) throws {
        guard !environment.contains(where: {
            isTelemetryKey($0.key) || $0.key == "CLAUDE_CONFIG_DIR"
        }) else { throw ClaudeSetupError.conflict }
    }

    public func permissionChange(configurationRoot: URL) throws -> PermissionChange? {
        let directory = try SettingsDirectory(configurationRoot, create: true)
        guard let (file, info) = try directory.openFile() else { return nil }
        defer { close(file) }
        guard info.st_mode & 0o077 != 0 else { return nil }
        return PermissionChange(configurationRoot: directory.url, directory: directory.identity, file: info)
    }

    public func makeSettingsPrivate(_ change: PermissionChange) throws {
        try withLock {
            let directory = try SettingsDirectory(change.configurationRoot, create: false)
            guard let (file, info) = try directory.openFile() else { throw ClaudeSetupError.changed }
            defer { close(file) }
            try directory.validateLocation()
            guard change.matches(directory: directory.identity, file: info) else { throw ClaudeSetupError.changed }
            guard fchmod(file, 0o600) == 0, fsync(file) == 0 else { throw ClaudeSetupError.storage }
            try directory.validateLocation()
            var current = stat()
            guard fstatat(directory.fd, "settings.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                  current.st_mode & 0o7777 == 0o600 else { throw ClaudeSetupError.changed }
        }
    }

    public func verify(_ receipt: Receipt) throws {
        let directory = try SettingsDirectory(receipt.configurationRoot, create: false)
        try directory.checkIdentity(receipt)
        guard receipt.committed else { throw ClaudeSetupError.interrupted }
        let document = try Self.document(directory.read())
        let environment = try Self.readEnvironment(document)
        let approved = Self.approvedEnvironment(receipt)
        guard approved.allSatisfy({ environment[$0.key] as? String == $0.value }),
              !Self.conflicts(document, environment: environment, approved: approved) else {
            throw ClaudeSetupError.ownership
        }
        if let command = receipt.statusLineCommand {
            guard Self.matchesStatusLine(document["statusLine"], command: command),
                  try PrivateFiles.read(statusLineRegistration, limit: 128) != nil else {
                throw ClaudeSetupError.ownership
            }
        }
        if receipt.sessionHooks != nil {
            guard try Self.sessionHooksMatch(receipt.sessionHooks, in: document),
                  try PrivateFiles.read(sessionRegistration, limit: 128) != nil else {
                throw ClaudeSetupError.ownership
            }
        }
    }

    public func install(configurationRoot: URL, configuration: TelemetryConfiguration,
                        policyReviewed: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                        managedPolicyPresent: Bool = Self.hasLocalManagedPolicy()) throws {
        guard policyReviewed else { throw ClaudeSetupError.review }
        guard !managedPolicyPresent else { throw ClaudeSetupError.policy }
        try Self.validateEnvironment(environment)
        try configuration.validate()
        guard configuration.port > 0 else { throw ClaudeSetupError.unavailable }
        try withLock {
            let directory = try SettingsDirectory(configurationRoot, create: true)
            let before = try directory.read()
            var document = try Self.document(before)
            var env = try Self.readEnvironment(document)
            let approved = Self.environment(configuration)
            let existing = try receipt()
            let permitted = existing.map(Self.approvedEnvironment) ?? approved
            guard !Self.conflicts(document, environment: env, approved: permitted) else { throw ClaudeSetupError.conflict }
            var saved: Receipt
            if let existing {
                guard existing.configurationRoot.standardizedFileURL == configurationRoot.standardizedFileURL,
                      existing.configuration.token == configuration.token,
                      existing.configuration.port == configuration.port else { throw ClaudeSetupError.ownership }
                try directory.checkIdentity(existing)
                guard existing.owned.allSatisfy({
                    env[$0.key] as? String == $0.value || (!existing.committed && env[$0.key] == nil)
                }), existing.statusLineCommand.map({
                    Self.matchesStatusLine(document["statusLine"], command: $0)
                }) ?? true,
                try Self.sessionHooksMatch(existing.sessionHooks, in: document) else { throw ClaudeSetupError.ownership }
                saved = existing
                for (key, value) in approved where env[key] == nil { saved.owned[key] = value }
            } else {
                saved = Receipt(version: 1, configurationRoot: configurationRoot.standardizedFileURL,
                    device: UInt64(directory.identity.st_dev), inode: directory.identity.st_ino,
                    configuration: configuration,
                    owned: approved.filter { env[$0.key] == nil },
                    createdEnvironment: document["env"] == nil, committed: false)
            }
            let removingLegacyMarker = saved.localAttribution == true && saved.owned["OTEL_RESOURCE_ATTRIBUTES"] != nil
            if removingLegacyMarker { env.removeValue(forKey: "OTEL_RESOURCE_ATTRIBUTES") }
            for (key, value) in approved { env[key] = value }
            document["env"] = env
            let after = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            guard after.count <= SettingsDirectory.limit else { throw ClaudeSetupError.storage }
            saved.committed = false
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
            try directory.replace(after, expecting: before)
            if removingLegacyMarker {
                saved.owned.removeValue(forKey: "OTEL_RESOURCE_ATTRIBUTES")
                saved.localAttribution = nil
            }
            saved.committed = true
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
        }
    }

    private var statusLineRegistration: URL { root.appendingPathComponent("claudeCLI.registration") }
    private var sessionRegistration: URL { root.appendingPathComponent("claudeSessions.registration") }
    private var statusLineCommand: String {
        let helper = root.appendingPathComponent("TokenotchHook").path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(helper)' claudeCLI statusLine"
    }

    private static func matchesStatusLine(_ value: Any?, command: String) -> Bool {
        guard let value = value as? NSDictionary else { return false }
        return value == ["type": "command", "command": command] as NSDictionary
    }

    private var sessionCommands: [String: String] {
        let helper = root.appendingPathComponent("TokenotchHook").path.replacingOccurrences(of: "'", with: "'\\''")
        return Dictionary(uniqueKeysWithValues: ["SessionStart", "SessionEnd"].map {
            ($0, "'\(helper)' claudeCLI \($0)")
        })
    }

    private static func sessionHook(_ command: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 1]]]
    }

    private static func hookMap(_ document: [String: Any]) throws -> [String: Any] {
        guard let value = document["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw ClaudeSetupError.conflict }
        return hooks
    }

    private static func hookGroups(_ hooks: [String: Any], event: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw ClaudeSetupError.conflict }
        return groups
    }

    private static func sessionHooksMatch(_ owned: SessionHooks?, in document: [String: Any]) throws -> Bool {
        guard let owned else { return true }
        let hooks = try hookMap(document)
        for (event, command) in owned.commands {
            guard try hookGroups(hooks, event: event).filter({
                $0 as NSDictionary == sessionHook(command) as NSDictionary
            }).count == 1 else { return false }
        }
        return true
    }

    public func enableSessionTracking(bundledHelper: URL) throws {
        try withLock {
            guard var saved = try receipt() else { throw ClaudeSetupError.interrupted }
            try verify(saved)
            if saved.sessionHooks != nil { return }
            let directory = try SettingsDirectory(saved.configurationRoot, create: false)
            try directory.checkIdentity(saved)
            let before = try directory.read()
            var document = try Self.document(before)
            var hooks = try Self.hookMap(document)
            let created = Set(sessionCommands.keys.filter { hooks[$0] == nil })
            for (event, command) in sessionCommands {
                var groups = try Self.hookGroups(hooks, event: event)
                guard !groups.contains(where: { $0 as NSDictionary == Self.sessionHook(command) as NSDictionary }) else {
                    throw ClaudeSetupError.ownership
                }
                groups.append(Self.sessionHook(command))
                hooks[event] = groups
            }
            let helper = root.appendingPathComponent("TokenotchHook")
            try PrivateFiles.write(Data(contentsOf: bundledHelper), to: helper)
            guard chmod(helper.path, 0o700) == 0 else { throw ClaudeSetupError.storage }
            try PrivateFiles.write(Data(UUID().uuidString.utf8), to: sessionRegistration)
            saved.sessionHooks = SessionHooks(commands: sessionCommands, createdContainer: document["hooks"] == nil,
                                              createdEvents: created)
            saved.committed = false
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
            document["hooks"] = hooks
            try directory.replace(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                  expecting: before)
            saved.committed = true
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
        }
    }

    private static func removeSessionHooks(from document: inout [String: Any], receipt: inout Receipt) throws {
        guard var owned = receipt.sessionHooks else { return }
        var hooks = try hookMap(document)
        for (event, command) in owned.commands {
            let groups = try hookGroups(hooks, event: event)
            let remaining = groups.filter { $0 as NSDictionary != sessionHook(command) as NSDictionary }
            let edited = remaining.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } == true
            }
            if !edited { owned.commands.removeValue(forKey: event) }
            if remaining.isEmpty && owned.createdEvents.contains(event) { hooks.removeValue(forKey: event) }
            else if hooks[event] != nil { hooks[event] = remaining }
        }
        if hooks.isEmpty && owned.createdContainer { document.removeValue(forKey: "hooks") }
        else if document["hooks"] != nil { document["hooks"] = hooks }
        receipt.sessionHooks = owned.commands.isEmpty ? nil : owned
    }

    public func disableSessionTracking() throws {
        try withLock {
            if try PrivateFiles.read(sessionRegistration, limit: 128) != nil {
                guard unlink(sessionRegistration.path) == 0 else { throw ClaudeSetupError.storage }
            }
            guard var saved = try receipt(), saved.sessionHooks != nil else { return }
            let directory = try SettingsDirectory(saved.configurationRoot, create: false)
            try directory.checkIdentity(saved)
            let before = try directory.read()
            var document = try Self.document(before)
            try Self.removeSessionHooks(from: &document, receipt: &saved)
            try directory.replace(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                  expecting: before)
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
            guard saved.sessionHooks == nil else { throw ClaudeSetupError.ownership }
        }
    }

    public func enableStatusLine(bundledHelper: URL) throws {
        try withLock {
            guard var saved = try receipt() else { throw ClaudeSetupError.interrupted }
            try verify(saved)
            let directory = try SettingsDirectory(saved.configurationRoot, create: false)
            try directory.checkIdentity(saved)
            let before = try directory.read()
            var document = try Self.document(before)
            if let command = saved.statusLineCommand {
                guard Self.matchesStatusLine(document["statusLine"], command: command) else { throw ClaudeSetupError.ownership }
                return
            }
            guard document["statusLine"] == nil else { throw ClaudeSetupError.statusLineConflict }
            let helper = root.appendingPathComponent("TokenotchHook")
            try PrivateFiles.write(Data(contentsOf: bundledHelper), to: helper)
            guard chmod(helper.path, 0o700) == 0 else { throw ClaudeSetupError.storage }
            try PrivateFiles.write(Data(UUID().uuidString.utf8), to: statusLineRegistration)
            saved.statusLineCommand = statusLineCommand
            saved.committed = false
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
            document["statusLine"] = ["type": "command", "command": statusLineCommand]
            try directory.replace(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                  expecting: before)
            saved.committed = true
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
        }
    }

    public func disableStatusLine() throws {
        try withLock {
            if try PrivateFiles.read(statusLineRegistration, limit: 128) != nil {
                guard unlink(statusLineRegistration.path) == 0 else { throw ClaudeSetupError.storage }
            }
            guard var saved = try receipt(), let command = saved.statusLineCommand else { return }
            let directory = try SettingsDirectory(saved.configurationRoot, create: false)
            try directory.checkIdentity(saved)
            let before = try directory.read()
            var document = try Self.document(before)
            if document["statusLine"] != nil {
                guard Self.matchesStatusLine(document["statusLine"], command: command) else { throw ClaudeSetupError.ownership }
                document.removeValue(forKey: "statusLine")
                try directory.replace(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                                      expecting: before)
            }
            saved.statusLineCommand = nil
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
        }
    }

    /// False means edited entries were preserved and cleanup still needs review.
    @discardableResult
    public func remove() throws -> Bool {
        try withLock {
            if try PrivateFiles.read(statusLineRegistration, limit: 128) != nil {
                guard unlink(statusLineRegistration.path) == 0 else { throw ClaudeSetupError.storage }
            }
            if try PrivateFiles.read(sessionRegistration, limit: 128) != nil {
                guard unlink(sessionRegistration.path) == 0 else { throw ClaudeSetupError.storage }
            }
            guard var saved = try receipt() else { return true }
            let directory = try SettingsDirectory(saved.configurationRoot, create: false)
            try directory.checkIdentity(saved)
            let before = try directory.read()
            var document = try Self.document(before)
            var env = try Self.readEnvironment(document)
            var changed: [String: String] = [:]
            for (key, value) in saved.owned {
                if env[key] as? String == value { env.removeValue(forKey: key) }
                else if env[key] != nil { changed[key] = value }
            }
            if let command = saved.statusLineCommand {
                if Self.matchesStatusLine(document["statusLine"], command: command) {
                    document.removeValue(forKey: "statusLine")
                    saved.statusLineCommand = nil
                } else if document["statusLine"] == nil { saved.statusLineCommand = nil }
            }
            try Self.removeSessionHooks(from: &document, receipt: &saved)
            if env.isEmpty && saved.createdEnvironment { document.removeValue(forKey: "env") }
            else if document["env"] != nil { document["env"] = env }
            if before != nil {
                let after = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                try directory.replace(after, expecting: before)
            }
            if changed.isEmpty && saved.statusLineCommand == nil && saved.sessionHooks == nil {
                guard unlink(receiptURL.path) == 0 else { throw ClaudeSetupError.storage }
                return true
            }
            saved.owned = changed
            try PrivateFiles.write(try JSONEncoder().encode(saved), to: receiptURL)
            return false
        }
    }

    private static func document(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSetupError.conflict
        }
        return value
    }

    private static func readEnvironment(_ document: [String: Any]) throws -> [String: Any] {
        guard let env = document["env"] else { return [:] }
        guard let value = env as? [String: Any], value.values.allSatisfy({ $0 is String }) else {
            throw ClaudeSetupError.conflict
        }
        return value
    }

    private static func conflicts(_ document: [String: Any], environment: [String: Any],
                                  approved: [String: String]) -> Bool {
        document["otelHeadersHelper"] != nil || environment.contains {
            isTelemetryKey($0.key) && (approved[$0.key] == nil || $0.value as? String != approved[$0.key])
        }
    }

    private func prepareRoot() throws {
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw TokenotchError.unsafePath }
        try PrivateFiles.directory(root)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try prepareRoot()
        let fd = open(root.appendingPathComponent("claude-setup.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TokenotchError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ClaudeSetupError.storage }
        return try body()
    }
}

private final class SettingsDirectory {
    static let limit = 1_048_576
    let url: URL
    let fd: Int32
    let identity: stat

    init(_ url: URL, create: Bool) throws {
        self.url = url.standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/"),
              self.url.path == url.resolvingSymlinksInPath().path else { throw TokenotchError.unsafePath }
        if create, mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw TokenotchError.unsafePath }
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw TokenotchError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw TokenotchError.unsafePath
        }
        identity = info
    }
    deinit { close(fd) }

    func checkIdentity(_ receipt: ClaudeCodeInstallation.Receipt) throws {
        guard UInt64(identity.st_dev) == receipt.device, identity.st_ino == receipt.inode else {
            throw ClaudeSetupError.ownership
        }
    }

    func openFile() throws -> (Int32, stat)? {
        let file = openat(fd, "settings.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw TokenotchError.unsafePath }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0,
              info.st_size <= Self.limit else {
            close(file)
            throw TokenotchError.unsafePath
        }
        return (file, info)
    }

    func read() throws -> Data? {
        guard let (file, info) = try openFile() else { return nil }
        defer { close(file) }
        guard info.st_mode & 0o077 == 0 else { throw ClaudeSetupError.permissions }
        var data = Data(count: Int(info.st_size))
        let size = data.count
        let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, size) }
        guard count == size else { throw ClaudeSetupError.storage }
        return data
    }

    func validateLocation() throws {
        var current = stat()
        guard url.path == url.resolvingSymlinksInPath().path, lstat(url.path, &current) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFDIR,
              current.st_mode & 0o022 == 0 else { throw ClaudeSetupError.changed }
    }

    func replace(_ data: Data, expecting before: Data?) throws {
        guard data.count <= Self.limit else { throw ClaudeSetupError.storage }
        let name = ".tokenotch-\(UUID().uuidString)"
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw ClaudeSetupError.storage }
        defer { close(file); unlinkat(fd, name, 0) }
        let count = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, data.count) }
        guard count == data.count, fsync(file) == 0 else { throw ClaudeSetupError.storage }
        try validateLocation()
        guard try read() == before else { throw ClaudeSetupError.changed }
        guard renameat(fd, name, fd, "settings.json") == 0, fsync(fd) == 0 else { throw ClaudeSetupError.storage }
    }
}
