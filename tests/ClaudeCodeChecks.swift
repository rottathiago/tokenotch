import Foundation
import SQLite3
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum ClaudeCodeChecks {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let zone = TimeZone(secondsFromGMT: 0)!

    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() }
        catch is TelemetryError { return }
        catch is TokenotchError { return }
        catch is HistoryError { return }
        catch is TimelineError { return }
        catch is ClaudeSetupError { return }
        catch is ClaudeAccountError { return }
        throw Failure(description: "Unsupported observation or archive was accepted")
    }

    static func fixture(service: String = "claude-code", entry: String? = "cli",
                        session: String? = "synthetic-session", request: String? = "req_synthetic",
                        name: String = "claude_code.api_request", at: Date = now,
                        read: Int? = 40, write: Int? = 20, cost: String? = "123456",
                        fields: [String: [String: Any]] = [:], body: String? = nil,
                        includeEventName: Bool = true,
                        resourceFields: [String: [String: Any]] = [:]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var values: [String: [String: Any]] = [
            "event.name": ["stringValue": String(name.dropFirst("claude_code.".count))],
            "event.timestamp": ["stringValue": formatter.string(from: at)],
            "model": ["stringValue": "shared-model"],
            "input_tokens": ["intValue": "100"], "output_tokens": ["intValue": "10"],
            "duration_ms": ["doubleValue": 12.5],
            "prompt": ["stringValue": "synthetic-private-content"],
            "response": ["stringValue": "synthetic-private-content"],
            "tool_parameters": ["stringValue": "synthetic-private-content"],
            "error": ["stringValue": "synthetic-private-content"],
            "workspace.host_paths": ["arrayValue": ["values": [["stringValue": "/synthetic-private-path"]]]],
            "user.email": ["stringValue": "synthetic-private-identity"],
            "client_request_id": ["stringValue": "synthetic-private-client-request"]
        ]
        if let entry { values["app.entrypoint"] = ["stringValue": entry] }
        if let session { values["session.id"] = ["stringValue": session] }
        if let request { values["request_id"] = ["stringValue": request] }
        if let read { values["cache_read_tokens"] = ["intValue": String(read)] }
        if let write { values["cache_creation_tokens"] = ["intValue": String(write)] }
        if let cost { values["cost_usd_micros"] = ["intValue": cost] }
        values.merge(fields) { _, new in new }
        if !includeEventName { values.removeValue(forKey: "event.name") }
        var resource: [String: [String: Any]] = [
            "service.name": ["stringValue": service],
            "user.account_uuid": ["stringValue": "synthetic-private-identity"]
        ]
        resource.merge(resourceFields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["resourceLogs": [[
            "resource": ["attributes": resource.keys.sorted().map { ["key": $0, "value": resource[$0]!] }],
            "scopeLogs": [["logRecords": [[
                "timeUnixNano": String(UInt64(at.timeIntervalSince1970 * 1_000_000_000)),
                "body": ["stringValue": body ?? name],
                "attributes": values.keys.sorted().map { ["key": $0, "value": values[$0]!] }
            ]]]]
        ]]])
    }

    static func ownedSetup() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-claude-setup-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("client")
        try PrivateFiles.directory(client)
        let settings = client.appendingPathComponent("settings.json")
        let original: [String: Any] = ["theme": "dark", "hooks": ["Stop": [["matcher": "*"]]],
                                     "env": ["UNRELATED": "preserve", "OTEL_LOG_USER_PROMPTS": "0"]]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: original), to: settings)
        let installation = ClaudeCodeInstallation(root: root.appendingPathComponent("app"))
        let config = TelemetryConfiguration(port: 43819)
        func install(reviewed: Bool = true, env: [String: String] = [:], managed: Bool = false) throws {
            try installation.install(configurationRoot: client, configuration: config,
                policyReviewed: reviewed, environment: env, managedPolicyPresent: managed)
        }
        try rejects { try install(reviewed: false) }
        try rejects { try install(env: ["DISABLE_TELEMETRY": "1"]) }
        try rejects { try install(managed: true) }
        try require(try installation.receipt() == nil, "Blocked setup must not create ownership")
        try install()
        guard let receipt = try installation.receipt() else { throw Failure(description: "Missing setup receipt") }
        try require(receipt.committed && receipt.owned["OTEL_LOG_USER_PROMPTS"] == nil,
                    "Do not claim settings that already matched")
        try installation.verify(receipt)
        try require(receipt.localAttribution == nil && receipt.owned["OTEL_RESOURCE_ATTRIBUTES"] == nil,
                    "New CLI setup installed retired attribution settings")
        try addLegacyAttribution(installation)
        let legacy = try installation.receipt()!
        try installation.verify(legacy)
        try install()
        try require(try installation.receipt()?.localAttribution == nil &&
            installation.receipt()?.owned["OTEL_RESOURCE_ATTRIBUTES"] == nil,
            "CLI setup did not retire its unchanged owned marker")
        try addLegacyAttribution(installation, interruptedRemoval: true)
        try install()
        try installation.verify(installation.receipt()!)
        let installed = try PrivateFiles.read(settings)!
        var edited = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        var env = edited["env"] as! [String: String]
        env["OTEL_LOGS_EXPORTER"] = "console"
        edited["env"] = env
        edited["newUserSetting"] = true
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: edited), to: settings)
        try rejects { try installation.verify(receipt) }
        try require(try !installation.remove(), "Edited owned entries must report incomplete cleanup")
        let removed = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        let remaining = removed["env"] as! [String: String]
        try require(remaining == ["UNRELATED": "preserve", "OTEL_LOG_USER_PROMPTS": "0", "OTEL_LOGS_EXPORTER": "console"] &&
                    removed["newUserSetting"] as? Bool == true && removed["hooks"] != nil,
                    "Removal must preserve unrelated settings, hooks and user edits")
        try require(try installation.receipt()?.owned == ["OTEL_LOGS_EXPORTER": "otlp"], "Retain only unresolved ownership")
        env = remaining
        env.removeValue(forKey: "OTEL_LOGS_EXPORTER")
        edited = removed; edited["env"] = env
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: edited), to: settings)
        try require(try installation.remove() && installation.receipt() == nil, "Finish interrupted cleanup")
        for conflict in [
            ["OTEL_LOGS_EXPORTER": "none"], ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.invalid"],
            ["CLAUDE_CODE_ENABLE_TELEMETRY": "0"], ["OTEL_LOG_RAW_API_BODIES": "1"],
            ["OTEL_RESOURCE_ATTRIBUTES": "host.name=existing-collector"]
        ] {
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: ["env": conflict]), to: settings)
            try rejects { try install() }
            try require(try installation.receipt() == nil, "Do not replace an opt-out or external collector")
        }
        try PrivateFiles.write(Data("{}".utf8), to: settings)
        try install()
        var pending = try JSONSerialization.jsonObject(with: PrivateFiles.read(
            installation.root.appendingPathComponent("claude-settings-receipt.json"))!) as! [String: Any]
        pending["committed"] = false
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: pending),
                               to: installation.root.appendingPathComponent("claude-settings-receipt.json"))
        try rejects { try installation.verify(installation.receipt()!) }
        try install()
        try installation.verify(installation.receipt()!)
        try require(try installation.remove(), "Recover receipt-first interrupted setup")
        try require(chmod(settings.path, 0o644) == 0, "Set unsafe fixture permissions")
        try rejects { try install() }
        try require(chmod(settings.path, 0o600) == 0, "Restore fixture permissions")
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: root.appendingPathComponent("outside"))
        try rejects { try install() }
        try FileManager.default.removeItem(at: settings)
        try PrivateFiles.write(Data(repeating: 32, count: 1_048_577), to: settings)
        try rejects { try install() }
    }

    static func addLegacyAttribution(_ installation: ClaudeCodeInstallation, interruptedRemoval: Bool = false) throws {
        var saved = try installation.receipt()!
        let settings = saved.configurationRoot.appendingPathComponent("settings.json")
        var document = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        var environment = document["env"] as! [String: String]
        let marker = ActivityEvent.digest("claudeCode:local-installation:\(saved.configuration.token)")
        let value = "tokenotch.local_installation=\(marker)"
        environment["OTEL_RESOURCE_ATTRIBUTES"] = value
        document["env"] = environment
        saved.localAttribution = true
        saved.owned["OTEL_RESOURCE_ATTRIBUTES"] = value
        if interruptedRemoval {
            environment.removeValue(forKey: "OTEL_RESOURCE_ATTRIBUTES")
            document["env"] = environment
            saved.committed = false
        }
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), to: settings)
        try PrivateFiles.write(JSONEncoder().encode(saved), to: installation.root.appendingPathComponent("claude-settings-receipt.json"))
    }

    static func accountFixture(root: URL) throws -> URL {
        let executable = root.appendingPathComponent("mock-claude")
        let script = """
        #!/bin/sh
        [ "$#" = 2 ] && [ "$1" = auth ] && [ "$2" = status ] || exit 2
        [ -z "${ANTHROPIC_API_KEY-}" ] && [ -z "${OTEL_EXPORTER_OTLP_ENDPOINT-}" ] || exit 3
        [ -n "$CLAUDE_CONFIG_DIR" ] || exit 4
        printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"synthetic-private","accountUuid":"synthetic-private"}'

        """
        try PrivateFiles.write(Data(script.utf8), to: executable)
        try require(chmod(executable.path, 0o700) == 0, "Prepare mock Claude executable")
        return executable
    }

    static func account() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-claude-auth-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try accountFixture(root: root)
        let runtime = ClaudeAccountRuntime(executable: executable, configurationRoot: root.appendingPathComponent("client"))
        let status = try runtime.status()
        try require(status.signedIn && status.method == .claudeAI &&
            !String(describing: status).contains("synthetic-private"), "Auth status retained private identity fields")
        let signedOut = try ClaudeAuthenticationStatus.parse(Data("{\"loggedIn\":false,\"authMethod\":\"none\"}".utf8), exitCode: 1)
        try require(!signedOut.signedIn, "Signed-out status was not recognized")
        for data in [
            Data("{\"loggedIn\":true,\"authMethod\":\"none\"}".utf8),
            Data("{\"loggedIn\":true,\"authMethod\":\"future-private\"}".utf8),
            Data("{\"loggedIn\":\"true\",\"authMethod\":\"claude.ai\"}".utf8),
            Data(repeating: 32, count: 65_537)
        ] {
            try rejects { _ = try ClaudeAuthenticationStatus.parse(data, exitCode: 0) }
        }
        try rejects {
            _ = try ClaudeAuthenticationStatus.parse(Data("{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}".utf8), exitCode: 1)
        }
        try rejects {
            _ = try ClaudeAuthenticationStatus.parse(
                Data("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"configDirectory\":\"/different-config\"}".utf8),
                exitCode: 0, expectedRoot: root)
        }
    }

    static func settingsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-claude-permissions-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("client")
        try PrivateFiles.directory(client)
        let settings = client.appendingPathComponent("settings.json")
        let original = Data("{\"theme\":\"dark\",\"hooks\":{\"Stop\":[]}}".utf8)
        try PrivateFiles.write(original, to: settings)
        try require(chmod(client.path, 0o755) == 0 && chmod(settings.path, 0o644) == 0, "Prepare ordinary Claude permissions")
        let installation = ClaudeCodeInstallation(root: root.appendingPathComponent("app"))
        func mode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as! NSNumber).intValue
        }
        guard let change = try installation.permissionChange(configurationRoot: client) else {
            throw Failure(description: "Non-private settings did not request approval")
        }
        try require(change.currentPermissions == "0644" && mode(settings) == 0o644 &&
                    Data(contentsOf: settings) == original,
                    "Checking permissions changed the file before approval")
        try installation.makeSettingsPrivate(change)
        try require(try mode(settings) == 0o600 && mode(client) == 0o755 &&
                    PrivateFiles.read(settings) == original &&
                    installation.permissionChange(configurationRoot: client) == nil,
                    "Repair must change only the approved file's permissions")

        try require(chmod(settings.path, 0o644) == 0, "Reset synthetic permissions")
        let replaced = try installation.permissionChange(configurationRoot: client)!
        try original.write(to: settings, options: .atomic)
        try require(chmod(settings.path, 0o644) == 0, "Prepare replaced fixture")
        try rejects { try installation.makeSettingsPrivate(replaced) }
        try require(try mode(settings) == 0o644, "Replaced file was modified using stale approval")

        let edited = try installation.permissionChange(configurationRoot: client)!
        try Data("{\"theme\":\"changed-without-replacing-the-file\"}".utf8).write(to: settings)
        try rejects { try installation.makeSettingsPrivate(edited) }
        try require(try mode(settings) == 0o644, "Edited file was modified using stale approval")

        let relocated = try installation.permissionChange(configurationRoot: client)!
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: client, to: moved)
        try PrivateFiles.directory(client)
        try PrivateFiles.write(original, to: settings)
        try require(chmod(settings.path, 0o644) == 0, "Prepare replacement directory")
        try rejects { try installation.makeSettingsPrivate(relocated) }
        try require(try mode(settings) == 0o644, "Replacement root reused stale directory ownership")
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: moved.appendingPathComponent("settings.json"))
        try rejects { _ = try installation.permissionChange(configurationRoot: client) }
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.linkItem(at: moved.appendingPathComponent("settings.json"), to: settings)
        try rejects { _ = try installation.permissionChange(configurationRoot: client) }
        try FileManager.default.removeItem(at: settings)
        try require(try installation.permissionChange(configurationRoot: client) == nil, "A new settings file needs no permission repair")
    }

    private static func event(_ data: Data, file: String = #fileID, line: UInt = #line) throws -> ActivityEvent {
        let batch = try ClaudeCodeOTelNormalizer.decode(data, now: now)
        try require(batch.events.count == 1 && batch.rejected == 0,
                    "Expected one synthetic Claude call at \(file):\(line); rejected=\(batch.rejected)")
        return batch.events[0]
    }

    static func accounting() throws {
        let value = try event(fixture())
        let attributeNamed = try event(fixture(body: "synthetic-private-log-body"))
        try require(attributeNamed == value, "Documented event.name must identify API calls without relying on log body formatting")
        try require(try event(fixture(includeEventName: false)) == value,
                    "Exact API-request body fallback changed when its optional event.name is absent")
        let contradictory = try ClaudeCodeOTelNormalizer.decode(
            fixture(body: "claude_code.assistant_response"), now: now)
        try require(contradictory.events.isEmpty && contradictory.rejected == 1,
                    "Contradictory API/response event names were counted")
        try require(value.provider == .claudeCode && value.usageSource == .claudeCLI && value.version == 5,
                    "Claude must use its own versioned provider contract")
        try require(value.tokens?.input == 100 && value.tokens?.output == 10 &&
                    value.tokens?.cacheInput == 40 && value.tokens?.cacheWrite == 20,
                    "Claude's noncached input must not have cache counts subtracted")
        try require(value.tokens?.estimatedCostMicros == 123456 && value.tokens?.durationMs == 12.5,
                    "Preserve integer estimated cost and call duration")
        let bytes = try JSONEncoder().encode(value)
        try require(try JSONDecoder().decode(ActivityEvent.self, from: bytes) == value, "Observation round trip")
        let encoded = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["synthetic-private", "synthetic-session", "req_synthetic", "prompt", "workspace", "user.email"] {
            try require(!encoded.contains(forbidden), "Raw identity or content escaped the allowlist")
        }
        let missing = try event(fixture(read: nil, write: nil, cost: nil))
        try require(missing.tokens?.cacheInputReported == false && missing.tokens?.cacheWriteReported == false &&
                    missing.tokens?.estimatedCostMicros == nil, "Missing optional values became known zero")
        let zeros = try event(fixture(read: 0, write: 0, cost: "0"))
        try require(zeros.tokens?.cacheInputReported == true && zeros.tokens?.cacheWriteReported == true &&
                    zeros.tokens?.estimatedCostMicros == 0, "Reported zero became unavailable")
        let decimal = try event(fixture(cost: nil, fields: ["cost_usd": ["stringValue": "0.123456"]]))
        try require(decimal.tokens?.estimatedCostMicros == 123456, "Exact decimal conversion to integer micros")
        let number = try event(fixture(cost: nil, fields: ["cost_usd": ["doubleValue": 0.000001]]))
        try require(number.tokens?.estimatedCostMicros == 1, "Checked numeric decimal conversion")
        let preferred = try event(fixture(fields: ["cost_usd": ["stringValue": "not-used"]]))
        try require(preferred.tokens?.estimatedCostMicros == 123456, "Integer micros take precedence over decimal mirrors")
        for fields in [
            ["input_tokens": ["intValue": "-1"]],
            ["output_tokens": ["doubleValue": 1.5]],
            ["cache_read_tokens": ["intValue": "1000000001"]],
            ["cache_creation_tokens": ["intValue": "9223372036854775808"]],
            ["input_tokens": ["boolValue": true]],
            ["duration_ms": ["stringValue": "NaN"]],
            ["model": ["stringValue": "synthetic private content"]],
            ["cost_usd_micros": ["intValue": "9223372036854775808"]]
        ] as [[String: [String: Any]]] {
            let batch = try ClaudeCodeOTelNormalizer.decode(fixture(fields: fields), now: now)
            try require(batch.events.isEmpty && batch.rejected == 1, "Invalid numeric/model field was admitted")
        }
        for text in ["-0.1", "1000000.000001", "NaN", "1e309", "."] {
            let batch = try ClaudeCodeOTelNormalizer.decode(fixture(cost: nil, fields: ["cost_usd": ["stringValue": text]]), now: now)
            try require(batch.events.isEmpty && batch.rejected == 1, "Invalid cost was admitted: \(text)")
        }
        let copilot = try CopilotOTelNormalizer.decode(TelemetryChecks.fixture(model: "claude-model"),
                                                       source: .vscodeLocal, now: TelemetryChecks.now).events[0]
        try require(copilot.provider == .copilot && copilot.tokens?.input == 40 &&
                    copilot.tokens?.estimatedCostMicros == nil, "A Claude model changed Copilot provider or accounting")
        var legacy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        legacy["version"] = 4
        let wrongVersion = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: legacy))
        try rejects { try wrongVersion.validatePayload() }
        let wrongPair = ActivityEvent(source: .vscode, session: value.session, kind: .usage, timestamp: now,
                                     tokens: value.tokens, metricSource: .claudeCLI, metricSessionReported: true)
        try rejects { try wrongPair.validatePayload() }
        let guessedLifecycle = ActivityEvent(source: .claudeCLI, session: value.session, kind: .working, timestamp: now)
        try rejects { try guessedLifecycle.validatePayload() }
    }

    static func costPrecision() throws {
        let cases: [([String: Any], Int64)] = [
            (["stringValue": "0.0000025"], 3),
            (["doubleValue": 0.0000025], 3),
            (["stringValue": "0.0037500000000000003"], 3750),
            (["doubleValue": 0.0037500000000000003], 3750),
            (["stringValue": "0.0000001"], 0),
            (["doubleValue": 0.0000005], 1),
            (["stringValue": "1000000"], EstimatedCostCoverage.perCallLimit)
        ]
        for (cost, expected) in cases {
            let batch = try ClaudeCodeOTelNormalizer.decode(fixture(cost: nil, fields: [
                "model": ["stringValue": "claude-haiku-4-5-20251001"], "cost_usd": cost
            ]), now: now)
            try require(batch.rejected == 0 && batch.events.count == 1 &&
                batch.events[0].tokens?.estimatedCostMicros == expected &&
                batch.events[0].tokens?.model == "claude-haiku-4-5-20251001",
                "A valid fractional-micro or floating-point cost discarded the entire Haiku call")
        }
        for cost in [["stringValue": "1000000.0000004"], ["doubleValue": 1000000.0000004]] as [[String: Any]] {
            let batch = try ClaudeCodeOTelNormalizer.decode(fixture(cost: nil, fields: ["cost_usd": cost]), now: now)
            try require(batch.events.isEmpty && batch.claudeRejections == [.cost: 1],
                        "Rounding admitted an out-of-range or nonnumeric estimated cost")
        }
        let boolean = try ClaudeCodeOTelNormalizer.decode(
            fixture(cost: nil, fields: ["cost_usd": ["boolValue": true]]), now: now)
        try require(boolean.events.isEmpty && boolean.rejected == 1, "A boolean cost was treated as money")
    }

    static func admission() throws {
        for entry in [nil, "sdk-cli", "sdk-ts", "sdk-py", "claude-vscode", "unknown", "claude-in-slack"] as [String?] {
            let batch = try ClaudeCodeOTelNormalizer.decode(fixture(entry: entry), now: now)
            try require(batch.events.isEmpty && batch.unattributed == 1 && batch.rejected == 1 &&
                batch.claudeRejections == [.entrypoint: 1], "An excluded CLI entrypoint was admitted")
        }
        let conflict = try ClaudeCodeOTelNormalizer.decode(
            fixture(resourceFields: ["app.entrypoint": ["stringValue": "sdk-cli"]]),
            now: now)
        try require(conflict.events.isEmpty && conflict.claudeRejections == [.entrypoint: 1],
                    "Conflicting terminal launch attribution was admitted")
        let malformedEntry = try ClaudeCodeOTelNormalizer.decode(
            fixture(fields: ["app.entrypoint": ["intValue": "1"]]), now: now)
        try require(malformedEntry.events.isEmpty && malformedEntry.claudeRejections == [.payload: 1],
                    "A numeric OTLP value was mistaken for a CLI launch string")
        for entry in [nil, "cli", "sdk-cli"] as [String?] {
            let excluded = try ClaudeCodeOTelNormalizer.decode(fixture(service: "claude-code-desktop", entry: entry), now: now)
            try require(excluded.events.isEmpty && excluded.filtered == 1 && excluded.rejected == 0,
                        "A retired client was collected or poisoned CLI readiness")
        }
        let remote = try ClaudeCodeOTelNormalizer.decode(
            fixture(fields: ["ccr.session.id": ["stringValue": "synthetic-cloud"]]), now: now)
        try require(remote.events.isEmpty && remote.claudeRejections == [.remoteSession: 1],
                    "An explicit cloud marker was admitted or mislabeled as unsupported SDK metadata")
        let cli = try event(fixture())
        let withLegacyMarker = try event(fixture(fields: ["tokenotch.local_installation": ["stringValue": "retired-marker"]]))
        try require(cli == withLegacyMarker, "Retired attribution metadata changed CLI accounting")
        let terminal = try event(fixture(fields: ["terminal.type": ["stringValue": "vscode"]]))
        try require(terminal.usageSource == .claudeCLI, "A terminal embedded in VS Code stopped being CLI usage")
        for data in [
            try fixture(service: "other"),
            try fixture(fields: ["ccr.session.id": ["stringValue": "synthetic-remote"]])
        ] {
            let batch = try ClaudeCodeOTelNormalizer.decode(data, now: now)
            try require(batch.events.isEmpty && batch.unattributed == 1, "Unsupported producer or remote session was admitted")
        }
        for name in ["claude_code.subagent_completed", "claude_code.assistant_response",
                     "claude_code.api_response_body", "claude_code.user_prompt", "claude_code.api_error"] {
            let batch = try ClaudeCodeOTelNormalizer.decode(fixture(name: name), now: now)
            try require(batch.events.isEmpty && batch.filtered == 1, "Parent totals, content or response mirrors were counted")
        }
        let missingID = try ClaudeCodeOTelNormalizer.decode(fixture(request: nil, fields: [
            "event.sequence": ["intValue": "1"]]), now: now)
        try require(missingID.events.isEmpty && missingID.unidentified == 1 && missingID.rejected == 1,
                    "Process sequence or client identity was used as an unverified request fallback")
        try require(missingID.claudeRejections == [.requestIdentity: 1] &&
                    missingID.claudeEventMarkers == [.apiAttribute: 1],
                    "Diagnostic stages must reveal missing identity without exposing raw fields")
        let badCost = try ClaudeCodeOTelNormalizer.decode(fixture(cost: "invalid-private-cost"), now: now)
        try require(badCost.claudeRejections == [.cost: 1], "Numeric-only diagnostics lost the rejection stage")
        let namespaced = try ClaudeCodeOTelNormalizer.decode(fixture(fields: [
            "event.name": ["stringValue": "claude_code.api_request"]
        ]), now: now)
        try require(namespaced.events.isEmpty && namespaced.claudeEventMarkers == [.namespacedAPIAttribute: 1],
                    "Diagnostic event-marker classification must not relax event admission")
        let unlinked = try event(fixture(session: nil))
        let other = try event(fixture(session: nil, request: "req_other"))
        try require(unlinked.metricSessionReported == false && unlinked.session != other.session,
                    "Missing session identity created an invented shared session")
        var root = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        var resources = root["resourceLogs"] as! [[String: Any]]
        var scopes = resources[0]["scopeLogs"] as! [[String: Any]]
        let record = (scopes[0]["logRecords"] as! [[String: Any]])[0]
        var attributes = record["attributes"] as! [[String: Any]]
        attributes.append(["key": "input_tokens", "value": ["intValue": "1"]])
        var duplicate = record
        duplicate["attributes"] = attributes
        scopes[0]["logRecords"] = [record, duplicate, record]
        resources[0]["scopeLogs"] = scopes
        root["resourceLogs"] = resources
        let mixed = try ClaudeCodeOTelNormalizer.decode(JSONSerialization.data(withJSONObject: root), now: now)
        try require(mixed.events.count == 2 && mixed.rejected == 1, "Rejected log record hid valid neighbors or ambiguous duplicate attributes")
        var ledger = TokenLedger()
        for value in mixed.events { try ledger.observe(value, now: now) }
        try require(ledger.totals?.calls == 1, "Repeated batch counted its valid record twice")
        scopes[0]["logRecords"] = Array(repeating: record, count: ClaudeCodeOTelNormalizer.recordLimit)
        resources[0]["scopeLogs"] = scopes
        root["resourceLogs"] = resources
        let boundary = try ClaudeCodeOTelNormalizer.decode(JSONSerialization.data(withJSONObject: root), now: now)
        try require(boundary.events.count == ClaudeCodeOTelNormalizer.recordLimit, "Exact record limit rejected")
        scopes[0]["logRecords"] = Array(repeating: record, count: ClaudeCodeOTelNormalizer.recordLimit + 1)
        resources[0]["scopeLogs"] = scopes
        root["resourceLogs"] = resources
        try rejects { _ = try ClaudeCodeOTelNormalizer.decode(JSONSerialization.data(withJSONObject: root), now: now) }
        for data in [Data("synthetic-private-invalid-json".utf8), Data("{\"resourceMetrics\":[]}".utf8),
                     Data("{\"resourceLogs\":[],\"resourceSpans\":[]}".utf8)] {
            try rejects { _ = try ClaudeCodeOTelNormalizer.decode(data, now: now) }
        }
        try rejects { _ = try ClaudeCodeOTelNormalizer.decode(Data(repeating: 0, count: ClaudeCodeOTelNormalizer.bodyLimit + 1)) }
        try rejects { _ = try CopilotOTelNormalizer.decode(fixture(), source: .claudeCLI, now: now) }
        let config = TelemetryConfiguration(port: 43817)
        let data = try fixture()
        let header = "POST /\(config.token)/claudeCLI/v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
        try rejects { _ = try OTLPRequest.parse(Data(header.utf8) + data, configuration: config) }
        try require(try OTLPRequest.parse(Data(header.utf8) + data, configuration: config, provider: .claudeCode)?.source == .claudeCLI,
                    "Explicit Claude receiver cannot admit its owned logs route")
        let copilotHeader = header.replacingOccurrences(of: "/claudeCLI/v1/logs", with: "/vscodeLocal/v1/traces")
        try rejects { _ = try OTLPRequest.parse(Data(copilotHeader.utf8) + data, configuration: config, provider: .claudeCode) }
        try rejects { _ = try HookNormalizer.normalize(data, source: .claudeCLI, hook: "SessionStart", now: now) }
        try rejects { _ = try HookInstallation().configuration(.claudeDesktop, helper: URL(fileURLWithPath: "/synthetic-helper")) }
    }

    static func providerDeletion() throws {
        let claude = try event(fixture())
        let copilot = SourceHistoryChecks.event("delete-provider", source: .cli, at: now)
        for provider in UsageProvider.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-provider-delete-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = try UsageHistoryStore(root: root, zone: zone, now: now.addingTimeInterval(-60))
            let timeline = try SessionTimelineStore(root: root, now: now)
            try history.record([claude, copilot], now: now)
            try history.heartbeat(from: now.addingTimeInterval(-30), to: now, active: true, sources: [.cli, .claudeCLI])
            try timeline.record([claude, copilot], retention: .seven, now: now)
            let survivor = provider == .copilot ? claude : copilot
            let interval = history.clock.interval(.today, selected: now, now: now)
            let before = try history.query(interval, provider: survivor.provider)
            let hourly = try history.hourlyTimeline(now: now, provider: survivor.provider)
            try history.delete(provider: provider)
            try timeline.delete(provider: provider)
            let after = try history.query(interval, provider: survivor.provider)
            try require(after.totals == before.totals &&
                after.recordingCoverage?.starts == before.recordingCoverage?.starts &&
                history.query(interval, provider: provider).totals.calls == 0 &&
                history.hourlyTimeline(now: now, provider: survivor.provider) == hourly,
                "Provider deletion changed the other provider's counts, coverage or hourly detail")
            try require(try history.query(interval).totals == after.totals &&
                history.record([survivor], now: now) == 0, "Provider deletion lost another provider's replay receipts")
            try timeline.record([survivor], retention: .seven, now: now)
            try require(try timeline.sessions(provider: provider).isEmpty &&
                timeline.sessions(provider: survivor.provider).count == 1 &&
                timeline.events(session: timeline.sessionID(source: survivor.source, hash: survivor.session)).events.count == 1,
                "Timeline provider deletion changed retained events or receipts")
            try require(try history.record([provider == .copilot ? copilot : claude], now: now) == 1,
                "Explicit provider deletion did not remove that provider's receipts")
        }
    }

    private static func archivedClient(_ event: ActivityEvent) -> ActivityEvent {
        ActivityEvent(source: .claudeDesktop, session: event.session, kind: .usage, timestamp: event.timestamp,
            tokens: event.tokens, metricSource: .claudeDesktop, metricSessionReported: event.metricSessionReported)
    }

    static func handoff() throws {
        let cli = try event(fixture())
        let mirror = archivedClient(cli)
        let desktop = archivedClient(try event(fixture(request: "req_desktop", at: now.addingTimeInterval(-1), cost: nil)))
        try require(cli.session == desktop.session && cli.tokens?.callID == mirror.tokens?.callID,
                    "Session or request namespace depends on the current client")
        var ledger = TokenLedger()
        for value in [cli, mirror, desktop, cli] { try ledger.observe(value, now: now) }
        try require(ledger.totals?.calls == 2 && ledger.totals?.total == 340 &&
                    ledger.totals?.costCoverage.value == 123456 && ledger.totals?.costCoverage.isIncomplete == true,
                    "Replay inflated calls/tokens/cost or made missing cost look free")
        try require(ledger.filtered(.claudeCLI).totals?.calls == 1 &&
                    ledger.filtered(.claudeDesktop).totals?.calls == 1 &&
                    ledger.bySession.count == 1 && ledger.bySession[0].sources == [.claudeCLI, .claudeDesktop],
                    "Handoff rewrote per-call origin or split a provider session")
        let copilot = SourceHistoryChecks.event("same-model", source: .cli, at: now, model: "shared-model")
        try ledger.observe(copilot, now: now)
        try require(ledger.byModel.count == 2 && Set(ledger.byModel.map(\.provider)) == [.copilot, .claudeCode] &&
                    Set(ledger.byModel.map(\.id)).count == 2 &&
                    ledger.filtered(provider: .copilot).totals?.calls == 1,
                    "All-provider model rows lost provider identity")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-claude-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var history: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: zone, now: now.addingTimeInterval(-60))
        var timeline: SessionTimelineStore? = try SessionTimelineStore(root: root, now: now)
        try require(try history!.record([cli, mirror, desktop, copilot], now: now) == 3, "Persisted handoff double counted")
        try timeline!.record([cli, mirror, desktop, copilot], retention: .seven, now: now)
        let session = timeline!.sessionID(source: .claudeCLI, hash: cli.session)
        try require(session == timeline!.sessionID(source: .claudeDesktop, hash: cli.session),
                    "Timeline namespace changes on handoff")
        let interval = history!.clock.interval(.today, selected: now, now: now)
        let snapshot = try history!.query(interval, provider: .claudeCode)
        try require(snapshot.totals.calls == 2 && snapshot.totals.total == 340 &&
                    snapshot.totals.costCoverage.value == 123456 && snapshot.totals.costReportedCalls == 1 &&
                    snapshot.comparisonBegan == nil, "Saved costs/coverage or unavailable consent baseline changed")
        try require(try history!.recordingBegan(source: .claudeCLI) == nil, "Calls implicitly started recording consent")
        try require(try history!.query(interval).models.count == 2 &&
                    history!.query(interval, provider: .copilot).totals.calls == 1 &&
                    history!.hourlyTimeline(now: now, provider: .claudeCode).calls == 2,
                    "Provider-scoped history/hourly queries merged or dropped observations")
        try rejects { _ = try history!.query(interval, source: .claudeCLI, provider: .copilot) }
        try rejects { _ = try history!.record([cli], now: now, importing: true) }
        let rows = try timeline!.events(session: session).events
        try require(rows.count == 2 && Set(rows.map(\.source)) == [.claudeCLI, .claudeDesktop] &&
                    rows.first { $0.source == .claudeCLI }?.estimatedCostMicros == 123456,
                    "Timeline lost cost or original client ownership")
        try require(try timeline!.sessions(provider: .claudeCode).count == 1 &&
                    timeline!.sessions(provider: .claudeCode)[0].clients == [.claudeCLI, .claudeDesktop],
                    "Shared-session client metadata is ambiguous")
        history = nil
        try timeline!.recording(true, now: now, provider: .claudeCode)
        timeline = nil
        let later = now.addingTimeInterval(601)
        history = try UsageHistoryStore(root: root, now: later)
        timeline = try SessionTimelineStore(root: root, now: later)
        try require(try timeline!.status(provider: .claudeCode).interrupted &&
                    !timeline!.status(provider: .copilot).interrupted,
                    "Claude recording interruption was attributed to Copilot")
        try require(try history!.record([mirror, desktop], now: later) == 0, "Restart lost durable request identity")
        try timeline!.record([mirror, desktop], retention: .seven, now: later)
        try require(try timeline!.events(session: session).events.map(\.id) == rows.map(\.id),
                    "Restart replay duplicated or moved a timeline call")
        let unlinked = try event(fixture(session: nil, request: "req_unlinked"))
        try timeline!.record([unlinked], retention: .seven, now: now)
        try require(try timeline!.sessions(provider: .claudeCode).count == 1, "Unlinked call invented an archived session")
        for file in ["history/usage.sqlite", "timeline/sessions.sqlite"] {
            let contents = String(decoding: try Data(contentsOf: root.appendingPathComponent(file)), as: UTF8.self)
            for text in ["synthetic-private", "synthetic-session", "req_synthetic", cli.session, cli.tokens!.callID] {
                try require(!contents.contains(text), "Private or stable raw identifiers persisted")
            }
        }
        try history!.heartbeat(from: now, to: now.addingTimeInterval(30), active: true, sources: [.cli])
        try history!.heartbeat(from: now, to: now.addingTimeInterval(30), active: true, sources: [.claudeCLI])
        let copilotBefore = try history!.query(interval, provider: .copilot)
        try history!.heartbeat(from: now.addingTimeInterval(30), to: now.addingTimeInterval(40),
                               active: false, sources: [.claudeCLI])
        let copilotAfter = try history!.query(interval, provider: .copilot)
        try require(copilotBefore.totals == copilotAfter.totals &&
                    copilotBefore.days.first?.recordingSeconds == copilotAfter.days.first?.recordingSeconds &&
                    history!.recordingBegan(source: .claudeCLI) == now,
                    "Changing Claude coverage interrupted Copilot or backdated consent")
        try sql(root.appendingPathComponent("history/usage.sqlite"), """
            UPDATE usage SET cost_micros=9223372036854775807 WHERE source='claudeCLI';
            """)
        let overflow = try event(fixture(request: "req_overflow", cost: "1"))
        try rejects { _ = try history!.record([overflow], now: now) }
        try require(try Self.rows(root.appendingPathComponent("history/usage.sqlite"),
                            "SELECT cost_micros,calls FROM usage WHERE source='claudeCLI'") == [[String(Int64.max), "1"]],
                    "Cost overflow committed a partial total or receipt")
        try sql(root.appendingPathComponent("history/usage.sqlite"), "UPDATE usage SET cost_micros=123456 WHERE source='claudeCLI'")
        try require(try history!.record([overflow], now: now) == 1, "Overflow rollback retained a receipt and suppressed a valid retry")
    }

    private static func sql(_ file: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw Failure(description: "Open fixture database") }
        defer { sqlite3_close(db) }
        try require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed")
    }
    private static func rows(_ file: URL, _ query: String) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw Failure(description: "Open fixture query") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try require(sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, "Prepare fixture query")
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try require(code == SQLITE_ROW, "Read fixture query")
            result.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL"
            })
        }
    }

    private static func legacyHistory(_ root: URL) throws -> URL {
        try PrivateFiles.directory(root)
        let directory = root.appendingPathComponent("history")
        try PrivateFiles.directory(directory)
        let file = directory.appendingPathComponent("usage.sqlite")
        try PrivateFiles.write(Data(), to: file)
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        try sql(file, """
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT INTO metadata VALUES ('zone','GMT'),('began','\(now.timeIntervalSince1970)'),
          ('hourly_began','\(now.timeIntervalSince1970)'),('receipt_key','\(key)');
        CREATE TABLE usage(day TEXT,source TEXT CHECK(source IN ('cli','vscodeLocal','vscodeCopilot')),
          model TEXT,accounting INTEGER,input INTEGER,output INTEGER,cache_input INTEGER,calls INTEGER,
          cache_reported_calls INTEGER,cache_unreported_calls INTEGER,cache_write INTEGER,
          write_reported_calls INTEGER,write_unreported_calls INTEGER,
          first_sum REAL,first_count INTEGER,duration_sum REAL,duration_count INTEGER,
          PRIMARY KEY(day,source,model,accounting));
        INSERT INTO usage VALUES ('\(HistoryCalendar(zone: zone).key(now))','cli','shared-model',0,100,20,7,2,0,0,0,0,0,4.5,1,9.25,1);
        CREATE TABLE context(day TEXT,source TEXT,maximum REAL,completed INTEGER,failed INTEGER,seen INTEGER,PRIMARY KEY(day,source));
        CREATE TABLE coverage(day TEXT,source TEXT,seconds REAL,gap INTEGER,imported INTEGER,PRIMARY KEY(day,source));
        INSERT INTO coverage VALUES ('\(HistoryCalendar(zone: zone).key(now))','all',12.75,1,0),
          ('\(HistoryCalendar(zone: zone).key(now))','cli',12.75,1,0);
        CREATE TABLE hourly_usage(start REAL,source TEXT,tokens INTEGER,calls INTEGER,seconds REAL,gap INTEGER,PRIMARY KEY(start,source));
        INSERT INTO hourly_usage VALUES (\(HistoryCalendar(zone: zone).hour(containing: now).start.timeIntervalSince1970),'cli',127,2,12.75,1),
          (\(HistoryCalendar(zone: zone).hour(containing: now).start.timeIntervalSince1970),'all',0,0,12.75,1);
        CREATE TABLE receipts(id TEXT PRIMARY KEY,time REAL);
        INSERT INTO receipts VALUES ('\(ActivityEvent.digest("legacy-receipt"))',\(now.timeIntervalSince1970));
        CREATE TABLE durable_receipts(id TEXT PRIMARY KEY);
        INSERT INTO durable_receipts VALUES ('\(String(repeating: "b", count: 64))');
        CREATE TABLE coverage_intervals(day TEXT,source TEXT,start REAL,end REAL,PRIMARY KEY(day,source,start));
        INSERT INTO coverage_intervals VALUES ('\(HistoryCalendar(zone: zone).key(now))','all',
          \(now.timeIntervalSince1970),\(now.timeIntervalSince1970 + 12.75));
        PRAGMA user_version=6;
        """)
        return file
    }

    static func migrations() throws {
        for broken in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-claude-migration-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = try legacyHistory(root)
            if broken { try sql(file, "UPDATE metadata SET value='invalid-zone' WHERE key='zone'") }
            let oldRows = try rows(file, "SELECT * FROM usage")
            let oldSchema = try rows(file, "SELECT sql FROM sqlite_master ORDER BY name")
            let oldKey = try rows(file, "SELECT value FROM metadata WHERE key='receipt_key'")
            if broken {
                try rejects { _ = try UsageHistoryStore(root: root, now: now) }
                try require(try rows(file, "PRAGMA user_version") == [["6"]] &&
                            rows(file, "SELECT * FROM usage") == oldRows &&
                            rows(file, "SELECT sql FROM sqlite_master ORDER BY name") == oldSchema,
                            "Failed provider migration did not roll back schema and original data")
            } else {
                var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: .current, now: now)
                let interval = store!.clock.interval(.today, selected: now, now: now)
                let copilot = try store!.query(interval, provider: .copilot)
                let claude = try store!.query(interval, provider: .claudeCode)
                try require(copilot.totals.input == 100 && copilot.totals.cacheInput == 7 &&
                            copilot.totals.calls == 2 && copilot.totals.unverifiedCalls == 2 &&
                            copilot.totals.cacheCoverage.unknownCalls == 2 && copilot.totals.costCoverage.value == nil &&
                            copilot.days.first?.recordingSeconds == 12.75 && claude.days.isEmpty,
                            "Migration changed Copilot accounting, unknown fields or provider coverage")
                try require(try rows(file, "SELECT * FROM usage").map { Array($0.prefix(oldRows[0].count)) } == oldRows &&
                            rows(file, "SELECT value FROM metadata WHERE key='receipt_key'") == oldKey &&
                            rows(file, "SELECT provider FROM durable_receipts") == [["copilot"]],
                            "Existing receipt identity or usage fields changed")
                try require(copilot.comparisonBegan == nil &&
                            copilot.recordingCoverage?.sources == [.cli],
                            "Legacy global coverage invented an exact per-source start")
                store = nil
                try sql(file, "PRAGMA user_version=999")
                let before = try Data(contentsOf: file)
                try rejects { _ = try UsageHistoryStore(root: root, now: now) }
                try require(try Data(contentsOf: file) == before, "Future schema was changed")
            }
        }
        for broken in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-claude-timeline-migration-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try PrivateFiles.directory(root)
            let directory = root.appendingPathComponent("timeline")
            try PrivateFiles.directory(directory)
            let file = directory.appendingPathComponent("sessions.sqlite")
            try PrivateFiles.write(Data(), to: file)
            let session = String(repeating: "c", count: 64), id = String(repeating: "d", count: 64)
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
                "id": id, "session": session, "source": "cli", "timestamp": now.timeIntervalSinceReferenceDate,
                "kind": "usage", "input": 10, "output": 2, "cacheInput": 3
            ]), as: UTF8.self)
            try sql(file, """
            CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            INSERT INTO metadata VALUES ('key','\(broken ? "invalid-key" : Data(repeating: 2, count: 32).base64EncodedString())'),('active','0');
            CREATE TABLE sessions(id TEXT PRIMARY KEY,source TEXT NOT NULL,truncated INTEGER NOT NULL DEFAULT 0);
            INSERT INTO sessions VALUES ('\(session)','cli',0);
            CREATE TABLE events(id TEXT PRIMARY KEY,session TEXT NOT NULL,time REAL NOT NULL,payload TEXT NOT NULL);
            INSERT INTO events VALUES ('\(id)','\(session)',\(now.timeIntervalSince1970),'\(payload)');
            CREATE TABLE receipts(id TEXT PRIMARY KEY,time REAL NOT NULL);
            INSERT INTO receipts VALUES ('\(id)',\(now.timeIntervalSince1970));
            PRAGMA user_version=3;
            """)
            let before = try rows(file, "SELECT sql FROM sqlite_master ORDER BY name")
            if broken {
                try rejects { _ = try SessionTimelineStore(root: root, now: now) }
                try require(try rows(file, "PRAGMA user_version") == [["3"]] &&
                            rows(file, "SELECT sql FROM sqlite_master ORDER BY name") == before,
                            "Timeline migration failure committed a partial schema")
            } else {
                let store = try SessionTimelineStore(root: root, now: now)
                let value = try store.events(session: session).events[0]
                try require(value.provider == .copilot && value.accountingVersion == nil &&
                            value.cacheInputReported == nil && value.cacheWriteReported == nil &&
                            value.estimatedCostMicros == nil && store.sessions(provider: .claudeCode).isEmpty,
                            "Legacy timeline acquired invented accounting, cost or provider metadata")
                try require(try rows(file, "SELECT payload FROM events") == [[payload]] &&
                            rows(file, "SELECT id FROM receipts") == [[id]],
                            "Migration rewrote legacy timeline JSON or receipts")
            }
        }
    }

    static func consent() throws {
        let domain = "tokenotch-claude-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "usageHistoryEnabled")
        defaults.set(true, forKey: "sessionTimelineEnabled")
        ProviderRecordingConsent.migrateCopilot(in: defaults)
        for kind in [RecordingKind.usageHistory, .sessionTimeline] {
            try require(ProviderRecordingConsent.enabled(kind, provider: .copilot, in: defaults) &&
                        !ProviderRecordingConsent.enabled(kind, provider: .claudeCode, in: defaults),
                        "Legacy consent was inherited by Claude")
            ProviderRecordingConsent.setEnabled(true, kind: kind, provider: .claudeCode, in: defaults)
            ProviderRecordingConsent.setEnabled(false, kind: kind, provider: .copilot, in: defaults)
            ProviderRecordingConsent.migrateCopilot(in: defaults)
            try require(!ProviderRecordingConsent.enabled(kind, provider: .copilot, in: defaults) &&
                        ProviderRecordingConsent.enabled(kind, provider: .claudeCode, in: defaults) &&
                        !defaults.bool(forKey: kind.rawValue), "Independent consent changed another provider or was remigrated")
        }
    }

    static func recordingWindows() throws {
        var windows = RecordingWindows<UsageSource>()
        let later = now.addingTimeInterval(30)
        windows.update([.cli], at: now)
        windows.update([.cli, .claudeCLI], at: later)
        try require(windows.accepts(.cli, at: now) && !windows.accepts(.claudeCLI, at: now),
                    "Adding Claude reset the retained CLI admission window or admitted pre-consent calls")
        windows.update([.cli], at: later.addingTimeInterval(30))
        windows.update([.cli, .claudeCLI], at: later.addingTimeInterval(60))
        try require(windows.starts[.cli] == now && windows.starts[.claudeCLI] == later.addingTimeInterval(60),
                    "Only the resumed source should get a new admission window")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-recording-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = HistoryCalendar(zone: zone)
        let periods = NotchHistorySummary.interval(now: now, calendar: clock)
        let start = periods.start.addingTimeInterval(-86_400)
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: zone, now: start)
        try store!.heartbeat(from: start, to: start, active: true, sources: [.cli])
        for index in 0..<14 {
            let date = clock.addingDays(index, to: periods.start).addingTimeInterval(3600)
            try store!.record([SourceHistoryChecks.event("baseline-\(index)", source: .cli, at: date)], now: now)
        }
        let before = try store!.query(periods, provider: .copilot)
        try require(try NotchHistorySummary(snapshot: before, now: now).change != nil,
                    "Consented Copilot fixture needs a comparable recording baseline")
        let cliStart = try store!.recordingBegan(source: .cli)
        try store!.heartbeat(from: now, to: later, active: true, sources: [.claudeCLI])
        let after = try store!.query(periods, provider: .copilot)
        try require(after.comparisonBegan == before.comparisonBegan && after.totals == before.totals &&
                    NotchHistorySummary(snapshot: after, now: now).change == NotchHistorySummary(snapshot: before, now: now).change,
                    "Connecting Claude changed Copilot's comparison baseline or samples")
        try require(try store!.recordingCoverage(provider: .claudeCode).comparisonBegan == now,
                    "Claude inherited the old archive creation or Copilot consent date")
        let desktopCall = archivedClient(try event(fixture(request: "req_new_window")))
        try store!.record([desktopCall], now: now)
        try require(try store!.recordingCoverage(provider: .claudeCode).comparisonBegan == nil,
                    "An unreported Desktop baseline became fully comparable")
        try store!.heartbeat(from: later, to: later, active: true, sources: [.claudeDesktop])
        try require(try store!.recordingCoverage(provider: .claudeCode).comparisonBegan == later,
                    "Provider comparison used the earliest source rather than the last admitted source")
        try store!.heartbeat(from: later, to: later, active: false, sources: [.claudeCLI])
        try require(try store!.recordingBegan(source: .cli) == cliStart &&
                    store!.query(periods, provider: .copilot).days.allSatisfy { !$0.gap },
                    "Pausing Claude changed Copilot's recording state")
        store = nil
        store = try UsageHistoryStore(root: root, now: later)
        try require(try store!.recordingBegan(source: .cli) == cliStart &&
                    store!.recordingBegan(source: .claudeCLI) == now &&
                    store!.recordingBegan(source: .claudeDesktop) == later,
                    "Restart lost independently persisted recording starts")
        store = nil
        let file = root.appendingPathComponent("history/usage.sqlite")
        try sql(file, "UPDATE metadata SET value='invalid-date' WHERE key='recording_began:claudeDesktop'")
        let metadata = try rows(file, "SELECT * FROM metadata ORDER BY key")
        try rejects { _ = try UsageHistoryStore(root: root, now: later) }
        try require(try rows(file, "SELECT * FROM metadata ORDER BY key") == metadata,
                    "Invalid source baseline reset data or committed a partial migration")
        let migratedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-source-baselines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: migratedRoot) }
        let migratedFile = try legacyHistory(migratedRoot)
        try sql(migratedFile, """
            INSERT INTO coverage_intervals VALUES ('\(clock.key(now))','vscodeLocal',
              \(later.timeIntervalSince1970),\(later.timeIntervalSince1970 + 5));
            """)
        let migrated = try UsageHistoryStore(root: migratedRoot, now: later)
        try require(try migrated.recordingBegan(source: .vscodeLocal) == later &&
                    migrated.recordingBegan(source: .cli) == nil &&
                    migrated.recordingBegan(source: .claudeCLI) == nil,
                    "Migration borrowed a global or another source's start instead of checkpoint evidence")
    }

    static func signalReadiness() throws {
        let configured = SignalReadiness(capability: .supported, enabled: true, configured: true, listening: true)
        try require(configured.delivery(now: now) == .waiting, "Configuration was mistaken for observed delivery")
        let metrics = SignalReadiness(capability: .supported, enabled: true, configured: true,
                                      listening: true, observed: now)
        let lifecycle = SignalReadiness(capability: .unverified, enabled: true, configured: true,
                                        listening: true, observed: now)
        let status = SourceSignalReadiness(source: .claudeCLI, metrics: metrics, lifecycle: lifecycle)
        try require(status.metrics.delivery(now: now) == .receiving &&
                    status.lifecycle.delivery(now: now) == .unverified,
                    "Numeric metrics certified unverified lifecycle hooks")
        try require(metrics.delivery(now: now.addingTimeInterval(300)) == .receiving &&
                    metrics.delivery(now: now.addingTimeInterval(301)) == .stale,
                    "Signal freshness boundary changed")
        try require(SignalReadiness(capability: .unsupported, enabled: true, configured: true,
                                    listening: true, observed: now).delivery(now: now) == .unsupported,
                    "Delivered observations enabled an unsupported signal")
        let rejected = SignalReadiness(capability: .supported, enabled: true, configured: true,
                                       listening: true, observed: now, rejectedAt: now.addingTimeInterval(1))
        try require(rejected.delivery(now: now) == .rejected, "Unsupported batch was shown as current valid delivery")
        let unavailable = SignalReadiness(capability: .supported, enabled: true, configured: true, observed: now)
        try require(unavailable.delivery(now: now) == .unavailable && metrics.delivery(now: now) == .receiving,
                    "An independent signal failure stopped the other signal")
    }

    static func statusLineFixture(session: String = "synthetic-session", at: Date = now,
                                  context: Bool = true, quotas: Bool = true,
                                  fields: [String: Any] = [:]) throws -> Data {
        let currentUsage: Any
        if context {
            currentUsage = ["input_tokens": 1_000, "output_tokens": 50_000,
                            "cache_read_input_tokens": 30_000, "cache_creation_input_tokens": 9_000]
        } else { currentUsage = NSNull() }
        var object: [String: Any] = [
            "session_id": session, "cwd": "/synthetic-private-path",
            "transcript_path": "/synthetic-private-path/transcript.jsonl",
            "session_name": "synthetic-private-title",
            "context_window": [
                "context_window_size": 200_000, "total_input_tokens": 900_000,
                "used_percentage": 99,
                "current_usage": currentUsage
            ]
        ]
        if quotas {
            object["rate_limits"] = [
                "five_hour": ["used_percentage": 23.5, "resets_at": at.addingTimeInterval(3_600).timeIntervalSince1970],
                "seven_day": ["used_percentage": 81.0, "resets_at": at.addingTimeInterval(86_400).timeIntervalSince1970]
            ]
        }
        object.merge(fields) { _, value in value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func statusLine() throws {
        let snapshot = try ClaudeStatusLineSnapshot.parse(statusLineFixture(), now: now)
        let usage = try ClaudeCodeOTelNormalizer.decode(fixture(), now: now).events[0]
        try require(snapshot.session == usage.session && snapshot.context?.currentTokens == 40_000 &&
            snapshot.context?.tokenLimit == 200_000 && snapshot.quotas.map(\.usedPercentage) == [23.5, 81],
            "Status line must link the OTel session and use current input/cache, not cumulative or output tokens")
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        try require(!encoded.contains("synthetic-private") && !encoded.contains("transcript") &&
            !encoded.contains("synthetic-session"), "Status-line forwarding retained private fields")
        try require(snapshot.quotas[0].isStale(observedAt: now, now: now.addingTimeInterval(301)) &&
            snapshot.quotas[0].isStale(observedAt: now.addingTimeInterval(3_590), now: now.addingTimeInterval(3_600)),
            "Idle or expired quota must not look current")

        var ledger = TokenLedger()
        try ledger.observe(usage, now: now)
        var state = ClaudeStatusLineState()
        try state.observe(snapshot, now: now)
        let merged = state.merging(ledger.bySession, provider: .claudeCode, source: nil, now: now)
        try require(merged.count == 1 && merged[0].context?.usage.currentTokens == 40_000 &&
            merged[0].tokens?.total == 170 && merged[0].source == .claudeCLI,
            "Status-line context duplicated the session or changed per-call token totals")
        let other = try ClaudeStatusLineSnapshot.parse(statusLineFixture(session: "another-session", at: now),
                                                       now: now.addingTimeInterval(1))
        try state.observe(other, now: now.addingTimeInterval(1))
        try require(state.merging(ledger.bySession, provider: .claudeCode, source: nil, now: now).count == 2 &&
            state.latest?.quotas[0].usedPercentage == 23.5,
            "Concurrent sessions must not sum account quotas")
        try require(state.merging([], provider: .copilot, source: nil, now: now).isEmpty &&
            state.merging([], provider: nil, source: .vscodeLocal, now: now).isEmpty,
            "Claude context leaked into another provider or source")
        let unavailable = try ClaudeStatusLineSnapshot.parse(statusLineFixture(context: false, quotas: false),
                                                              now: now.addingTimeInterval(2))
        try state.observe(unavailable, now: now.addingTimeInterval(2))
        try state.observe(snapshot, now: now.addingTimeInterval(2))
        let reset = state.merging(ledger.bySession, provider: .claudeCode, source: nil, now: now)
        try require(reset.first { $0.id == snapshot.session }?.context == nil && state.latest?.quotas.isEmpty == true,
            "A compacted/missing context or quota must become unavailable; delayed readings cannot restore it")
        state.expire(now: now.addingTimeInterval(86_403))
        try require(state.latest == nil &&
            state.merging([], provider: .claudeCode, source: nil, now: now.addingTimeInterval(86_403)).isEmpty,
            "Status-line sessions exceeded their retention bound")
        for invalid: [String: Any] in [
            ["rate_limits": ["five_hour": ["used_percentage": true, "resets_at": now.timeIntervalSince1970]]],
            ["rate_limits": ["five_hour": ["used_percentage": 101, "resets_at": now.timeIntervalSince1970]]],
            ["rate_limits": ["seven_day": ["used_percentage": -1, "resets_at": now.timeIntervalSince1970]]],
            ["rate_limits": ["five_hour": ["used_percentage": 1, "resets_at": false]]],
            ["rate_limits": ["five_hour": ["used_percentage": 1]]],
            ["context_window": ["context_window_size": 0, "current_usage": [
                "input_tokens": 1, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 3]]],
            ["context_window": ["context_window_size": 200_000, "current_usage": [
                "input_tokens": 1.5, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 3]]],
            ["context_window": ["context_window_size": 200_000, "current_usage": [
                "input_tokens": 1, "cache_read_input_tokens": -2, "cache_creation_input_tokens": 3]]],
            ["session_id": ""]
        ] {
            try rejects { _ = try ClaudeStatusLineSnapshot.parse(statusLineFixture(fields: invalid), now: now) }
        }
        try rejects { _ = try ClaudeStatusLineSnapshot.parse(Data(repeating: 32, count: HookNormalizer.inputLimit + 1), now: now) }
    }

    static func statusLineSetup() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-claude-statusline-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("client")
        let installation = ClaudeCodeInstallation(root: root.appendingPathComponent("app's files"))
        try installation.install(configurationRoot: client, configuration: TelemetryConfiguration(port: 43819),
            policyReviewed: true, environment: [:], managedPolicyPresent: false)
        let settings = client.appendingPathComponent("settings.json")
        let before = try PrivateFiles.read(settings)!
        var document = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        let userLine = ["type": "command", "command": "echo user-line", "padding": "1"]
        document["statusLine"] = userLine
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document), to: settings)
        let conflict = try PrivateFiles.read(settings)!
        try rejects { try installation.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true")) }
        try require(try PrivateFiles.read(settings) == conflict &&
            installation.receipt()?.statusLineCommand == nil, "Existing status line was replaced or adopted")
        try PrivateFiles.write(before, to: settings)
        try installation.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        let receipt = try installation.receipt()!
        try installation.verify(receipt)
        try require(receipt.statusLineCommand?.contains("'\\''") == true &&
            PrivateFiles.read(installation.root.appendingPathComponent("claudeCLI.registration")) != nil,
            "Status-line setup did not safely quote its helper or register the private bridge")
        try installation.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        try installation.disableStatusLine()
        try installation.verify(installation.receipt()!)
        let disabled = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! NSDictionary
        let original = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        try require(disabled == original && installation.receipt()?.statusLineCommand == nil,
                    "Disabling status line changed telemetry or unrelated settings")
        try installation.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        document = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        document["statusLine"] = userLine
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document), to: settings)
        try require(try !installation.remove(), "Edited status-line ownership did not require cleanup review")
        document = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        try require(document["statusLine"] as? [String: String] == userLine &&
            PrivateFiles.read(installation.root.appendingPathComponent("claudeCLI.registration")) == nil,
            "Removal changed the user's status line or left collection authorized")
        document.removeValue(forKey: "statusLine")
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document), to: settings)
        try require(try installation.remove() && installation.receipt() == nil, "Status-line cleanup could not finish")
    }

    static func sessionHookFixture(_ hook: String, session: String = "synthetic-session",
                                   fields: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "hook_event_name": hook, "session_id": session,
            "cwd": "/synthetic-private-path", "transcript_path": "/synthetic-private-path/transcript.jsonl",
            "prompt": "synthetic-private-content", "reason": "prompt_input_exit", "source": "startup"
        ]
        object.merge(fields) { _, value in value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func sessionLifecycle() throws {
        let start = try ClaudeSessionEvent.parse(sessionHookFixture("SessionStart"), hook: "SessionStart", now: now)!
        let end = try ClaudeSessionEvent.parse(sessionHookFixture("SessionEnd"), hook: "SessionEnd",
                                               now: now.addingTimeInterval(1))!
        let usage = try ClaudeCodeOTelNormalizer.decode(fixture(), now: now).events[0]
        var ledger = TokenLedger()
        try ledger.observe(usage, now: now)
        let copilot = ActivityEvent(source: .cli, session: usage.session, kind: .usage, timestamp: now,
            tokens: TokenUsage(callID: ActivityEvent.digest("copilot-call"), input: 1, output: 2))
        try ledger.observe(copilot, now: now)
        var state = ClaudeSessionState()
        try state.observe(start, now: now)
        try require(state.openSessions == [usage.session], "Session hooks do not share numeric session identity")
        try state.observe(end, now: now.addingTimeInterval(1))
        let visible = state.visible(ledger.filtered(provider: .claudeCode).bySession)
        try require(visible.isEmpty && ledger.totals?.calls == 2 && state.openSessions.isEmpty,
                    "SessionEnd did not hide Claude metrics independently of usage totals")
        try require(state.visible(ledger.filtered(provider: .copilot).bySession).count == 1,
                    "Closing Claude hid a Copilot session with the same hash")
        try state.observe(start, now: now.addingTimeInterval(2))
        try state.observe(end, now: now.addingTimeInterval(2))
        try require(state.openSessions.isEmpty, "A delayed start resurrected a closed session")
        let resumed = try ClaudeSessionEvent.parse(sessionHookFixture("SessionStart"), hook: "SessionStart",
                                                   now: now.addingTimeInterval(3))!
        try state.observe(resumed, now: now.addingTimeInterval(3))
        try require(state.openSessions == [usage.session] &&
            state.visible(ledger.filtered(provider: .claudeCode).bySession).count == 1,
            "Resuming a session did not withdraw its end marker")
        let encoded = String(decoding: try JSONEncoder().encode(end), as: UTF8.self)
        try require(!encoded.contains("synthetic") && !encoded.contains("transcript") &&
            !encoded.contains("prompt_input_exit"), "Session hooks forwarded private input or unnecessary fields")
        try require(try ClaudeSessionEvent.parse(sessionHookFixture("SessionEnd", fields: ["agent_id": "child"]),
                                                hook: "SessionEnd", now: now) == nil,
                    "A subagent end closed the parent session")
        try rejects { _ = try ClaudeSessionEvent.parse(sessionHookFixture("Stop"), hook: "Stop", now: now) }
        try rejects { _ = try ClaudeSessionEvent.parse(sessionHookFixture("SessionEnd"), hook: "SessionStart", now: now) }
        try rejects { _ = try ClaudeSessionEvent.parse(sessionHookFixture("SessionEnd", session: ""), hook: "SessionEnd", now: now) }
        try rejects { try end.validate(now: now.addingTimeInterval(122)) }
    }

    static func sessionHookSetup() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-claude-session-hooks-\(UUID().uuidString)")
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("client")
        let installation = ClaudeCodeInstallation(root: root.appendingPathComponent("app's files"))
        try installation.install(configurationRoot: client, configuration: TelemetryConfiguration(port: 43819),
            policyReviewed: true, environment: [:], managedPolicyPresent: false)
        let settings = client.appendingPathComponent("settings.json")
        var document = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        let user: [String: Any] = ["hooks": [["type": "command", "command": "echo user-hook"]]]
        document["hooks"] = ["SessionStart": [user], "SessionEnd": [user], "Stop": [user]]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document), to: settings)
        try installation.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        let before = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! NSDictionary
        try installation.enableSessionTracking(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        try installation.enableSessionTracking(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        try installation.verify(installation.receipt()!)
        var hooks = (try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any])["hooks"] as! [String: [[String: Any]]]
        try require(hooks["SessionStart"]?.count == 2 && hooks["SessionEnd"]?.count == 2 &&
            hooks["Stop"]?.count == 1, "Session setup replaced user hooks, duplicated handlers or observed Stop")
        try installation.disableStatusLine()
        try require(try PrivateFiles.read(installation.root.appendingPathComponent("claudeSessions.registration")) != nil,
                    "Quota withdrawal revoked session-hook consent")
        try installation.enableStatusLine(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        try installation.disableSessionTracking()
        try installation.verify(installation.receipt()!)
        let restored = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! NSDictionary
        try require(restored == before &&
            PrivateFiles.read(installation.root.appendingPathComponent("claudeCLI.registration")) != nil &&
            PrivateFiles.read(installation.root.appendingPathComponent("claudeSessions.registration")) == nil,
            "Session withdrawal changed unrelated settings, quota consent or left hooks authorized")
        try installation.enableSessionTracking(bundledHelper: URL(fileURLWithPath: "/usr/bin/true"))
        document = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        hooks = document["hooks"] as! [String: [[String: Any]]]
        var edited = hooks["SessionEnd"]![1]
        var handlers = edited["hooks"] as! [[String: Any]]
        handlers[0]["timeout"] = 9
        edited["hooks"] = handlers
        hooks["SessionEnd"]![1] = edited
        document["hooks"] = hooks
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document), to: settings)
        try require(try !installation.remove(), "Edited session hook was deleted without cleanup review")
        document = try JSONSerialization.jsonObject(with: PrivateFiles.read(settings)!) as! [String: Any]
        hooks = document["hooks"] as! [String: [[String: Any]]]
        try require(hooks["SessionStart"]?.count == 1 && hooks["SessionEnd"]?.count == 2 &&
            hooks["SessionEnd"]![1] as NSDictionary == edited as NSDictionary &&
            PrivateFiles.read(installation.root.appendingPathComponent("claudeSessions.registration")) == nil,
            "Cleanup changed user hooks or left edited hooks authorized")
        hooks["SessionEnd"] = [user]
        document["hooks"] = hooks
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: document), to: settings)
        try require(try installation.remove() && installation.receipt() == nil, "Session-hook cleanup could not finish")
    }

    static func run() throws {
        try sessionLifecycle()
        try sessionHookSetup()
        try statusLine()
        try statusLineSetup()
        try accounting()
        try costPrecision()
        try admission()
        try handoff()
        try migrations()
        try consent()
        try recordingWindows()
        try signalReadiness()
        print("PASS: synthetic Claude accounting, attribution, handoff identity, privacy, migration rollback and isolated consent.")
    }
}
