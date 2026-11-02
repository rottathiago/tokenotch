import Foundation

@main
enum TelemetrySmoke {
    static func main() throws {
        try TelemetryChecks.run()
        try SourceHistoryChecks.run()
        try TelemetryImportChecks.run()
        try ClaudeCodeChecks.run()
        try ClaudeCodeChecks.account()
        try ClaudeCodeChecks.ownedSetup()
        try ClaudeCodeChecks.settingsPermissions()
        try ClaudeCodeChecks.providerDeletion()
        try receiver()
        try claudeReceiver()
    }

    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        var configuration: TelemetryConfiguration?
        var status: Int?
        var events: [ActivityEvent] = []
    }

    static func receiver() throws {
        let server = OTLPReceiver()
        let ready = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let results = Results()
        server.onReady = { config in
            results.lock.lock()
            results.configuration = config
            results.lock.unlock()
            ready.signal()
        }
        server.onFailure = { _ in ready.signal() }
        server.onBatch = { _, batch, done in
            results.lock.lock()
            results.events.append(contentsOf: batch.events)
            results.lock.unlock()
            done(true)
        }
        try server.start(TelemetryConfiguration())
        defer { server.stop() }
        guard ready.wait(timeout: .now() + 5) == .success else { throw TelemetryError.unavailable }
        results.lock.lock()
        let configuration = results.configuration
        results.lock.unlock()
        guard let configuration, configuration.port > 0 else { throw TelemetryError.unavailable }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        for (source, suffix, signal, streamed) in [(UsageSource.vscodeLocal, "/v1/traces", "traces", false),
                                                  (.vscodeCopilot, "/v1/traces", "traces", false),
                                                  (.vscodeCopilot, "", "traces", false),
                                                  (.vscodeCopilot, "", "metrics", false),
                                                  (.vscodeCopilot, "", "logs", false),
                                                  (.vscodeLocal, "/v1/traces", "traces", true),
                                                  (.vscodeLocal, "/v1/metrics", "metrics", true)] {
            var request = URLRequest(url: URL(string: configuration.endpoint(source) + suffix)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = try signal == "traces" ? TelemetryChecks.fixture(source: source, model: "gpt-5.6-sol", at: now) :
                Data("{\"\(signal == "metrics" ? "resourceMetrics" : "resourceLogs")\":[]}".utf8)
            if streamed { request.httpBodyStream = InputStream(data: body) }
            else { request.httpBody = body }
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request) { _, response, _ in
                results.lock.lock()
                results.status = (response as? HTTPURLResponse)?.statusCode
                results.lock.unlock()
                delivered.signal()
            }.resume()
            guard delivered.wait(timeout: .now() + 10) == .success else { throw TelemetryError.unavailable }
            results.lock.lock()
            let status = results.status
            results.lock.unlock()
            guard status == 200 else { throw TelemetryError.invalid }
        }
        results.lock.lock()
        let events = results.events
        results.lock.unlock()
        var ledger = TokenLedger()
        for event in events { try ledger.observe(event, now: now) }
        let models = ledger.todayByModel(now: now)
        guard events.count == 4, ledger.totals?.calls == 2,
              models.count == 1, models.first?.model == "gpt-5.6-sol",
              models.first?.tokens.total == 220 else { throw TelemetryError.invalid }
        print("PASS: fixed-length and streamed telemetry deliver Sol usage without double-counting calls.")
    }

    static func claudeReceiver() throws {
        let server = OTLPReceiver(provider: .claudeCode)
        let copilot = OTLPReceiver()
        let ready = DispatchSemaphore(value: 0), copilotReady = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let results = Results(), copilotResults = Results()
        server.onReady = { config in
            results.lock.lock(); results.configuration = config; results.lock.unlock()
            ready.signal()
        }
        copilot.onReady = { config in
            copilotResults.lock.lock(); copilotResults.configuration = config; copilotResults.lock.unlock()
            copilotReady.signal()
        }
        server.onBatch = { _, batch, done in
            results.lock.lock(); results.events += batch.events; results.lock.unlock()
            done(true)
        }
        copilot.onBatch = { _, batch, done in
            copilotResults.lock.lock(); copilotResults.events += batch.events; copilotResults.lock.unlock()
            done(true)
        }
        try server.start(TelemetryConfiguration())
        try copilot.start(TelemetryConfiguration())
        defer { server.stop(); copilot.stop() }
        guard ready.wait(timeout: .now() + 5) == .success,
              copilotReady.wait(timeout: .now() + 5) == .success,
              let configuration = results.configuration, let copilotConfig = copilotResults.configuration else {
            throw TelemetryError.unavailable
        }
        let now = Date()
        func send(_ body: Data, to url: String, expected: Int, rejection: String? = nil) throws {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request) { body, response, _ in
                let text = String(decoding: body ?? Data(), as: UTF8.self)
                results.lock.lock()
                results.status = rejection.map { text.contains($0) } ?? true ? (response as? HTTPURLResponse)?.statusCode : nil
                results.lock.unlock()
                delivered.signal()
            }.resume()
            guard delivered.wait(timeout: .now() + 10) == .success, results.status == expected else {
                throw TelemetryError.invalid
            }
        }
        let logs = try ClaudeCodeChecks.fixture(at: now)
        try send(logs, to: configuration.endpoint(.claudeCLI) + "/v1/logs", expected: 200)
        let missing = try ClaudeCodeChecks.fixture(request: nil, at: now)
        try send(missing, to: configuration.endpoint(.claudeCLI) + "/v1/logs", expected: 200, rejection: "rejectedLogRecords")
        try send(logs, to: copilotConfig.endpoint(.claudeCLI) + "/v1/logs", expected: 401)
        try send(logs, to: configuration.endpoint(.vscodeLocal) + "/v1/traces", expected: 401)
        try send(try ClaudeCodeChecks.fixture(service: "claude-code-desktop", entry: nil, at: now),
                 to: configuration.endpoint(.claudeCLI) + "/v1/logs", expected: 200)
        try send(Data("{\"resourceSpans\":[]}".utf8), to: configuration.endpoint(.claudeCLI) + "/v1/traces", expected: 200)
        server.stop()
        try send(try TelemetryChecks.fixture(at: now), to: copilotConfig.endpoint(.vscodeLocal) + "/v1/traces", expected: 200)
        guard results.events.count == 1, results.events[0].usageSource == .claudeCLI,
              copilotResults.events.count == 1 else { throw TelemetryError.invalid }
        print("PASS: isolated Claude logs routing, sanitized partial-log responses and independent Copilot receiver lifetime.")
    }
}
