import Darwin
import Foundation
import TokenotchCore

/// Temporary CLI-only acceptance; no automated inference or saved settings edits.
@main
enum ClaudeAcceptance {
    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var rejected = 0
        var unattributed = 0
        var unidentified = 0
        var unlinked = 0
        var filtered = 0
        var failed = false
    }

    static func main() {
        do {
            let status = try run()
            exit(status)
        } catch {
            fputs("Acceptance could not finish; no client settings were changed.\n", stderr)
            exit(1)
        }
    }

    static func run() throws -> Int32 {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--launch-preflight" {
            guard !hasEnvironmentConflict() else {
                fputs("Telemetry/configuration environment conflicts; nothing was changed. Do not start the acceptance session.\n", stderr)
                return 2
            }
            print("Temporary CLI acceptance launcher started; no saved settings will change.")
            return 0
        }
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--consented-cli",
              CommandLine.arguments[2].hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: CommandLine.arguments[2]) else {
            fputs("Requires explicit user approval: --consented-cli /absolute/path/to/claude\n", stderr)
            return 2
        }
        guard !hasEnvironmentConflict() else {
            fputs("Existing telemetry/configuration environment requires review; nothing was changed.\n", stderr)
            return 2
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/claude-acceptance-\(UUID().uuidString)", isDirectory: true)
        try PrivateFiles.directory(root)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Temporary acceptance launcher cleanup failed; remove its named private directory.\n", stderr) }
        }
        let receiver = OTLPReceiver(provider: .claudeCode)
        defer { receiver.stop() }
        let result = Results()
        let completed = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        receiver.onReady = { configuration in
            do {
                func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let values = [
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
                let settings = values.keys.sorted().map { quote("\($0)=\(values[$0]!)") }.joined(separator: " ")
                let launcher = root.appendingPathComponent("Claude CLI acceptance.command")
                let checker = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
                let command = """
                #!/bin/sh
                cd \(quote(FileManager.default.currentDirectoryPath)) || exit 1
                \(quote(checker)) --launch-preflight || exit 1
                /usr/bin/curl --silent --fail --max-time 5 -X POST -H 'Content-Type: application/json' --data '{"resourceLogs":[]}' \(quote(configuration.endpoint(.claudeCLI) + "/v1/logs")) > /dev/null || exit 1
                exec /usr/bin/env \(settings) \(quote(CommandLine.arguments[2]))

                """
                try PrivateFiles.write(Data(command.utf8), to: launcher)
                guard chmod(launcher.path, 0o700) == 0 else { throw TokenotchError.storage }
                print("READY port=\(configuration.port)")
                print("LAUNCHER \(launcher.path)")
                fflush(stdout)
                ready.signal()
            } catch {
                result.lock.lock(); result.failed = true; result.lock.unlock()
                fputs("Could not create the private temporary launcher; no client settings changed.\n", stderr)
                ready.signal()
                completed.signal()
            }
        }
        receiver.onBatch = { source, batch, done in
            guard source == .claudeCLI else { done(false); return }
            result.lock.lock()
            result.calls += batch.events.count
            result.rejected += batch.rejected
            result.unattributed += batch.unattributed
            result.unidentified += batch.unidentified
            result.unlinked += batch.unlinked
            result.filtered += batch.filtered
            result.lock.unlock()
            for event in batch.events {
                guard let tokens = event.tokens else { continue }
                print("CLI API request accepted; session=\(event.metricSessionReported == true ? "reported" : "unlinked"), " +
                      "cacheRead=\(tokens.cacheInputReported == true ? "reported" : "not-reported"), " +
                      "cacheWrite=\(tokens.cacheWriteReported == true ? "reported" : "not-reported"), " +
                      "cost=\(tokens.estimatedCostMicros == nil ? "not-reported" : "reported")")
            }
            print("BATCH accepted=\(batch.events.count) rejected=\(batch.rejected) unattributed=\(batch.unattributed) missingRequestID=\(batch.unidentified) ignored=\(batch.filtered)")
            let markers = batch.claudeEventMarkers.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue)=\(batch.claudeEventMarkers[$0]!)" }
            let stages = batch.claudeRejections.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue)=\(batch.claudeRejections[$0]!)" }
            if !markers.isEmpty { print("MARKERS " + markers.joined(separator: " ")) }
            if !stages.isEmpty { print("REJECTION STAGES " + stages.joined(separator: " ")) }
            fflush(stdout)
            done(true)
        }
        receiver.onFailure = { error in
            print("Receiver failure: \(error == .unauthorized ? "unauthorized" : error == .capacity ? "capacity" : "unsupported-or-unavailable")")
            fflush(stdout)
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { completed.signal() }
        terminate.setEventHandler { completed.signal() }
        interrupt.resume(); terminate.resume()
        defer { interrupt.cancel(); terminate.cancel() }
        try receiver.start(TelemetryConfiguration())
        guard ready.wait(timeout: .now() + 10) == .success else { throw TelemetryError.unavailable }
        if completed.wait(timeout: .now() + 600) == .timedOut {
            print("Acceptance window expired; receiver stopped. No client settings were changed.")
        }
        result.lock.lock()
        let calls = result.calls, rejected = result.rejected, unattributed = result.unattributed
        let unidentified = result.unidentified, unlinked = result.unlinked, filtered = result.filtered, failed = result.failed
        result.lock.unlock()
        print("RESULT accepted=\(calls) rejected=\(rejected) unattributed=\(unattributed) missingRequestID=\(unidentified) unlinked=\(unlinked) ignored=\(filtered)")
        print("Only sanitized capability counts were emitted. No client settings or telemetry archives were written.")
        return calls == 0 || failed ? 1 : 0
    }

    private static func hasEnvironmentConflict() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment.keys.contains {
            ($0.hasPrefix("OTEL_") || ["CLAUDE_CONFIG_DIR", "DISABLE_TELEMETRY",
             "DISABLE_NON_ESSENTIAL_MODEL_CALLS", "CLAUDE_CODE_ENABLE_TELEMETRY",
             "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA", "ENABLE_ENHANCED_TELEMETRY_BETA",
             "BETA_TRACING_ENDPOINT"].contains($0)) && !(environment[$0] ?? "").isEmpty
        }
    }
}
