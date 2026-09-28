import Foundation
import TokenotchCore
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum VSCodeIntegrationChecks {
    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() {
            throw NSError(domain: "VSCodeIntegrationChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func setupRequest() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000.625)
        let expiry = now.addingTimeInterval(600)
        let configuration = TelemetryConfiguration(port: 43817)
        let endpoints = Dictionary(uniqueKeysWithValues: [UsageSource.vscodeLocal, .vscodeCopilot].map {
            ($0.rawValue, configuration.endpoint($0))
        })
        for (operation, metrics) in [("configure", true), ("configure", false), ("remove", true)] {
            let request = VSCodeIntegrationController.SetupRequest(
                nonce: String(repeating: "a", count: 64), expiry: expiry,
                operation: operation, hooks: true, metrics: metrics,
                endpoints: operation == "configure" && metrics ? endpoints : nil)
            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let expiresAt = json?["expiresAt"] as? Double else {
                throw NSError(domain: "VSCodeIntegrationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Setup expiry must be a JSON number."])
            }
            try require(expiresAt == 1_790_000_600,
                        "The companion rejects fractional expiresAt; native setup must use whole Unix seconds.")
            try require(expiresAt > now.timeIntervalSince1970 && expiresAt <= now.timeIntervalSince1970 + 600,
                        "The request must be fresh within the companion's ten-minute limit.")
            try require(json?["operation"] as? String == operation && json?["metrics"] as? Bool == metrics,
                        "Preserve the requested setup operation and consent.")
            try require(json?["endpoints"] as? [String: String] ==
                        (operation == "configure" && metrics ? endpoints : nil),
                        "Preserve endpoints for metrics setup and allow endpoint-free removal.")
        }
    }

    static func modelUsage(_ model: String) throws {
        let now = TelemetryChecks.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageHistoryStore(root: root, now: now)
        let interval = store.clock.interval(.today, selected: now, now: now)
        var ledger = TokenLedger()
        let config = TelemetryConfiguration(port: 43817)
        for source in [UsageSource.vscodeLocal, .vscodeCopilot] {
            let data = try TelemetryChecks.fixture(source: source, model: model)
            let suffix = source == .vscodeLocal ? "/v1/traces" : ""
            let header = "POST /\(config.token)/\(source.rawValue)\(suffix) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
            guard let request = try OTLPRequest.parse(Data(header.utf8) + data, configuration: config) else {
                throw TelemetryError.invalid
            }
            try require(request.signal == "traces", "Route both SDK base URLs and Agent Host trace URLs.")
            let batch = try CopilotOTelNormalizer.decode(request.body, source: request.source, now: now)
            try require(batch.rejected == 0 && batch.filtered == 0 && batch.events.count == 1,
                        "Accept a \(model) call from either supported VS Code source.")
            let event = batch.events[0]
            try require(event.tokens?.model == model, "Preserve the reported model ID.")
            try ledger.observe(event, now: now)
            try ledger.observe(event, now: now)
            try require(try store.record([event], now: now) == 1, "Save model usage.")
            try require(try store.record([event], now: now) == 0, "Do not double-count a replayed model call.")
            let saved = try store.query(interval, source: source)
            try require(saved.models.first?.id == model && saved.models.first?.tokens.total == 110,
                        "Keep the model's inclusive total and identity in source-filtered history.")
        }
        let live = NotchPresentation(tokens: ledger.today(now: now), now: now,
                                     models: ledger.todayByModel(now: now))
        try require(live.modelRows.count == 1 && live.modelRows.first?.model == model
                    && live.modelRows.first?.tokens == 220 && live.modelRows.first?.calls == 2,
                    "Show the model's deduplicated usage in today's live notch model breakdown.")
        let saved = try store.query(interval)
        try require(live.usageTotals?.total == 220 && saved.totals.total == 220,
                    "Keep live and saved model totals consistent.")
    }

    static func receiverErrorRecovery() async throws {
        let name = "tokenotch-receiver-recovery-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "vscodeMetricsEnabled")
        let controller = VSCodeIntegrationController(defaults: defaults, root: root, openSetupURL: { _ in false })
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(condition(), "Timed out waiting for receiver status.")
        }
        controller.start()
        try await waitUntil { controller.ready }
        let config = try JSONDecoder().decode(TelemetryConfiguration.self,
            from: Data(contentsOf: root.appendingPathComponent("vscode-telemetry.json")))
        func send(_ body: Data, contentType: String = "application/json") async throws -> Int? {
            var request = URLRequest(url: URL(string: config.endpoint(.vscodeCopilot))!)
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        }
        let empty = Data("{\"resourceSpans\":[]}".utf8)
        let badStatus = try await send(empty, contentType: "application/x-protobuf")
        try require(badStatus == 400, "Reject unsupported export formats.")
        try await waitUntil { controller.failedRequests == 1 }
        try require(controller.error == TelemetryError.unsupported.rawValue && controller.ready,
                    "A request failure must be visible without stopping the listener.")
        let emptyStatus = try await send(empty)
        try require(emptyStatus == 200 && controller.error != nil,
                    "An empty batch is not proof that model usage recovered.")
        let metricsStatus = try await send(Data("{\"resourceMetrics\":[]}".utf8))
        try require(metricsStatus == 200 && controller.error != nil,
                    "Acknowledging metrics must not hide a model-usage failure.")

        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let filteredStatus = try await send(TelemetryChecks.fixture(source: .vscodeCopilot, operation: "invoke_agent", at: now))
        try require(filteredStatus == 200 && controller.error != nil && controller.excluded == 1,
                    "Filtered parent spans must not clear a receiver error.")
        let good = try TelemetryChecks.fixture(source: .vscodeCopilot, model: "gpt-5.6-sol", at: now)
        let invalid = try TelemetryChecks.fixture(source: .vscodeCopilot, input: 1, at: now)
        guard let goodEnvelope = try JSONSerialization.jsonObject(with: good) as? [String: Any],
              let invalidEnvelope = try JSONSerialization.jsonObject(with: invalid) as? [String: Any],
              let goodSpans = goodEnvelope["resourceSpans"] as? [[String: Any]],
              let invalidSpans = invalidEnvelope["resourceSpans"] as? [[String: Any]] else {
            throw TelemetryError.invalid
        }
        let partial = try JSONSerialization.data(withJSONObject: [
            "resourceSpans": goodSpans + invalidSpans
        ])
        let partialStatus = try await send(partial)
        try require(partialStatus == 200 && controller.rejected == 1 && controller.accepted[.vscodeCopilot] == 1 &&
                    controller.error == TelemetryError.invalid.rawValue,
                    "A mixed accepted/rejected batch still reports partial coverage.")
        let goodStatus = try await send(good)
        try require(goodStatus == 200 && controller.error == nil && controller.lastObservation[.vscodeCopilot] != nil,
                    "A clean model-usage batch clears the stale receiver error.")
        try require(controller.failedRequests == 1 && controller.rejected == 1 &&
                    controller.lastFailedRequestError == TelemetryError.unsupported.rawValue,
                    "Recovery preserves rejected request and observation diagnostics.")

        _ = try await send(empty, contentType: "application/x-protobuf")
        try await waitUntil { controller.failedRequests == 2 }
        try require(controller.error == TelemetryError.unsupported.rawValue,
                    "A new failure must become visible again after recovery.")
        controller.configure(metrics: true)
        let setupError = controller.error
        try require(setupError != nil && setupError != TelemetryError.unsupported.rawValue,
                    "Exercise a separate setup link failure.")
        _ = try await send(good)
        try require(controller.error == setupError && controller.pendingRequest != nil,
                    "Healthy telemetry must not erase an unresolved setup error.")
        controller.clearObservations()
        try require(controller.failedRequests == 0 && controller.lastFailedRequestError == nil && controller.error == nil,
                    "Explicitly clearing observations resets receiver diagnostics.")
    }
}
