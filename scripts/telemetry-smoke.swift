import Foundation

@main
enum TelemetrySmoke {
    static func main() throws {
        try TelemetryChecks.run()
        try SourceHistoryChecks.run()
        try TelemetryImportChecks.run()
        try receiver()
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
}
