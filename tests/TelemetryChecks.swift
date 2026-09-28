import Foundation
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum TelemetryChecks {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func fixture(source: UsageSource = .vscodeLocal, input: Int = 100, output: Int = 10,
                        read: Int? = 40, write: Int? = 20, conversation: String? = "synthetic-session",
                        operation: String = "chat", span: String = "1111111111111111",
                        model: String = "test-model",
                        at: Date = TelemetryChecks.now) throws -> Data {
        var attributes: [[String: Any]] = [
            ["key": "gen_ai.operation.name", "value": ["stringValue": operation]],
            ["key": "gen_ai.provider.name", "value": ["stringValue": "github"]],
            ["key": "gen_ai.response.model", "value": ["stringValue": model]],
            ["key": "gen_ai.usage.input_tokens", "value": ["intValue": "\(input)"]],
            ["key": "gen_ai.usage.output_tokens", "value": ["intValue": "\(output)"]],
            ["key": "gen_ai.input.messages", "value": ["stringValue": "private-content-must-not-survive"]]
        ]
        if let conversation { attributes.append(["key": "gen_ai.conversation.id", "value": ["stringValue": conversation]]) }
        if let read { attributes.append(["key": "gen_ai.usage.cache_read.input_tokens", "value": ["intValue": "\(read)"]]) }
        if let write { attributes.append(["key": "gen_ai.usage.cache_creation.input_tokens", "value": ["intValue": "\(write)"]]) }
        return try JSONSerialization.data(withJSONObject: ["resourceSpans": [[
            "resource": ["attributes": [
                ["key": "service.name", "value": ["stringValue": source == .vscodeLocal ? "copilot-chat" : "github-copilot"]],
                ["key": "service.namespace", "value": ["stringValue": "vscode.agent-host"]],
                ["key": "github.copilot.git.repository", "value": ["stringValue": "private-repository"]]
            ]],
            "scopeSpans": [["spans": [[
                "traceId": String(repeating: "a", count: 32), "spanId": span,
                "startTimeUnixNano": String(UInt64(at.addingTimeInterval(-1).timeIntervalSince1970 * 1_000_000_000)),
                "endTimeUnixNano": String(UInt64(at.timeIntervalSince1970 * 1_000_000_000)),
                "attributes": attributes
            ]]]]
        ]]])
    }

    static func run() throws {
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try condition() == false { throw NSError(domain: "TelemetryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let data = try fixture()
        let result = try CopilotOTelNormalizer.decode(data, source: .vscodeLocal, now: now)
        try require(result.events.count == 1 && result.rejected == 0, "Accept one supported call")
        let event = result.events[0]
        try require(event.usageSource == .vscodeLocal && event.source == .vscode, "Carry the metric source")
        try require(event.tokens?.input == 40 && event.tokens?.output == 10, "Normalize disjoint input")
        try require(event.tokens?.cacheInput == 40 && event.tokens?.cacheWrite == 20, "Preserve cache counts")
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        try require(!encoded.contains("private") && !encoded.contains("synthetic-session"), "Strip content and raw identity")
        let decoded = try JSONDecoder().decode(ActivityEvent.self, from: Data(encoded.utf8))
        try require(decoded == event, "Round-trip metric provenance")
        var ledger = TokenLedger()
        try ledger.observe(event, now: now)
        try ledger.observe(event, now: now)
        try require(ledger.totals?.calls == 1 && ledger.totals?.total == 110, "Deduplicate spans")
        let cli = ActivityEvent(source: .cli, session: ActivityEvent.digest("synthetic-session"), kind: .usage,
                                timestamp: now, tokens: TokenUsage(callID: ActivityEvent.digest("cli-call"), input: 7, output: 3))
        try ledger.observe(cli, now: now)
        try require(ledger.filtered(.cli).totals?.total == 10 && ledger.filtered(.vscodeLocal).totals?.total == 110,
                    "Source filters conserve totals")
        try require(ledger.totals?.total == 120 && ledger.bySession.count == 2, "Distinct sources do not merge sessions")
        ledger.remove(.cli)
        try require(ledger.totals?.total == 110, "Removing CLI preserves VS Code")
        let missing = try CopilotOTelNormalizer.decode(fixture(read: nil, write: nil, conversation: nil),
                                                      source: .vscodeLocal, now: now)
        try require(missing.events[0].tokens?.cacheInputReported == false && missing.unlinked == 1,
                    "Missing cache and session metadata remain unavailable")
        let root = try CopilotOTelNormalizer.decode(fixture(operation: "invoke_agent"), source: .vscodeLocal, now: now)
        try require(root.events.isEmpty && root.filtered == 1, "Exclude parent aggregate")
        let invalid = try CopilotOTelNormalizer.decode(fixture(input: 1), source: .vscodeLocal, now: now)
        try require(invalid.events.isEmpty && invalid.rejected == 1, "Reject contradictory categories")
        let terminal = try CopilotOTelNormalizer.decode(fixture(source: .vscodeCopilot), source: .vscodeLocal, now: now)
        try require(terminal.events.isEmpty && terminal.filtered == 1, "Exclude terminal CLI from Local endpoint")
        let host = try CopilotOTelNormalizer.decode(fixture(source: .vscodeCopilot), source: .vscodeCopilot, now: now)
        try require(host.events.count == 1, "Accept source-isolated Copilot host")
        let imported = try CopilotOTelNormalizer.decode(data, source: .vscodeLocal, now: now.addingTimeInterval(86400), importing: true)
        try require(imported.events[0].tokens?.callID == event.tokens?.callID, "Import identity equals live identity")
        try ledger.observe(event, now: now.addingTimeInterval(300), allowingDelayed: true)
        let hooks = try JSONSerialization.data(withJSONObject: [
            "session_id": "synthetic", "hook_event_name": "UserPromptSubmit",
            "timestamp": ISO8601DateFormatter().string(from: now)])
        try require(try HookNormalizer.normalizeObservation(hooks, source: .cli, hook: "userPromptSubmitted", now: now) == nil,
                    "Ignore Local payload delivered through discovered CLI hooks")
        let config = TelemetryConfiguration(port: 43817)
        let header = "POST /\(config.token)/vscodeLocal/v1/traces HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
        let bytes = Data(header.utf8) + data
        try require(try OTLPRequest.parse(bytes, configuration: config)?.source == .vscodeLocal, "Authenticated HTTP JSON")
        try require(try OTLPRequest.parse(Data(bytes.dropLast()), configuration: config) == nil, "Wait for complete body")
        for source in [UsageSource.vscodeLocal, .vscodeCopilot] {
            for signal in ["traces", "metrics", "logs"] {
                let route = "/\(config.token)/\(source.rawValue)/v1/\(signal)"
                let request = Data(header.replacingOccurrences(of: "/\(config.token)/vscodeLocal/v1/traces", with: route).utf8) + data
                let parsed = try OTLPRequest.parse(request, configuration: config)
                try require(parsed?.source == source && parsed?.signal == signal,
                            "Preserve conventional OTLP signal routes for both sources")
            }
        }
        let hostHeader = header.replacingOccurrences(of: "/vscodeLocal/v1/traces", with: "/vscodeCopilot")
        let hostRequest = try OTLPRequest.parse(Data(hostHeader.utf8) + data, configuration: config)
        try require(hostRequest?.source == .vscodeCopilot && hostRequest?.signal == "traces" && hostRequest?.body == data,
                    "Agent Host treats a configured non-root URL as the complete trace endpoint")
        try require(try OTLPRequest.parse(Data(hostHeader.utf8) + data.dropLast(), configuration: config) == nil,
                    "Direct Agent Host endpoint waits for the complete body")
        for (envelope, signal) in [("resourceSpans", "traces"), ("resourceMetrics", "metrics"), ("resourceLogs", "logs")] {
            let body = Data("{\"\(envelope)\":[]}".utf8)
            let requestHeader = hostHeader.replacingOccurrences(of: "Content-Length: \(data.count)", with: "Content-Length: \(body.count)")
            let parsed = try OTLPRequest.parse(Data(requestHeader.utf8) + body, configuration: config)
            try require(parsed?.signal == signal, "Distinguish signals sharing the direct Agent Host endpoint")
        }
        for envelope in ["{}", "{\"resourceSpans\":{},\"resourceMetrics\":[]}", "{\"resourceSpans\":[],\"resourceMetrics\":[]}",
                         "{\"resourceSpans\":null}", "{\"resourceMetrics\":\"invalid\"}"] {
            let body = Data(envelope.utf8)
            let requestHeader = hostHeader.replacingOccurrences(of: "Content-Length: \(data.count)", with: "Content-Length: \(body.count)")
            do {
                _ = try OTLPRequest.parse(Data(requestHeader.utf8) + body, configuration: config)
                throw NSError(domain: "TelemetryChecks", code: 4)
            } catch let error as TelemetryError {
                try require(error == .unsupported, "Reject unsupported or ambiguous direct-endpoint envelopes")
            }
        }
        for route in [
            "/\(String(repeating: "b", count: 64))/vscodeCopilot",
            "/vscodeCopilot", "/\(config.token)/cli", "/\(config.token)/unknown",
            "/\(config.token)/vscodeLocal", "/\(config.token)/vscodeCopilot/",
            "/\(config.token)/vscodeCopilot?signal=traces",
            "/\(config.token)/vscodeCopilot/v1", "/\(config.token)/vscodeCopilot/v1/unknown",
            "/\(config.token)/vscodeCopilot/v1/traces/extra"
        ] {
            let request = Data(header.replacingOccurrences(of: "/\(config.token)/vscodeLocal/v1/traces", with: route).utf8) + data
            do {
                _ = try OTLPRequest.parse(request, configuration: config)
                throw NSError(domain: "TelemetryChecks", code: 3)
            } catch let error as TelemetryError {
                try require(error == .unauthorized, "Direct trace support must not bypass token or exact-route validation")
            }
        }
        for malformed in [
            bytes + Data([0]),
            Data(header.replacingOccurrences(of: config.token, with: String(repeating: "b", count: 64)).utf8) + data,
            Data(header.replacingOccurrences(of: "Host: 127.0.0.1", with: "Origin: http://example.invalid").utf8) + data,
            Data(header.replacingOccurrences(of: "Content-Type:", with: "Content-Encoding: gzip\r\nContent-Type:").utf8) + data,
            Data(hostHeader.replacingOccurrences(of: "application/json", with: "application/x-protobuf").utf8) + data,
            Data(hostHeader.replacingOccurrences(of: "Host: 127.0.0.1", with: "Origin: http://example.invalid").utf8) + data
        ] {
            do {
                _ = try OTLPRequest.parse(malformed, configuration: config)
                throw NSError(domain: "TelemetryChecks", code: 2)
            } catch is TelemetryError {}
        }
        let chunkedHeader = header.replacingOccurrences(of: "Content-Length: \(data.count)", with: "Transfer-Encoding: chunked")
        let chunk = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n0\r\n\r\n".utf8)
        let chunked = Data(chunkedHeader.utf8) + chunk
        try require(try OTLPRequest.parse(chunked, configuration: config)?.body == data,
                    "Accept the chunked HTTP body used by VS Code's JavaScript OTel exporter")
        for length in 0..<chunked.count {
            try require(try OTLPRequest.parse(Data(chunked.prefix(length)), configuration: config) == nil,
                        "Wait for a complete chunked request at every possible network split")
        }
        let first = data.prefix(data.count / 2), second = data.dropFirst(first.count)
        let twoChunks = Data("\(String(first.count, radix: 16, uppercase: true))\r\n".utf8) + first +
            Data("\r\n\(String(second.count, radix: 16))\r\n".utf8) + second + Data("\r\n0\r\n\r\n".utf8)
        let multiChunk = Data(chunkedHeader.utf8) + twoChunks
        try require(try OTLPRequest.parse(multiChunk, configuration: config)?.body == data,
                    "Decode multiple chunks with either hex case")
        let maximumBody = Data(repeating: 32, count: CopilotOTelNormalizer.bodyLimit)
        let maximumRequest = Data((chunkedHeader + "\(String(maximumBody.count, radix: 16))\r\n").utf8) +
            maximumBody + Data("\r\n0\r\n\r\n".utf8)
        try require(try OTLPRequest.parse(maximumRequest, configuration: config)?.body.count == maximumBody.count,
                    "Accept the exact decoded-body limit without counting chunk framing as payload")
        let maximumChunks = Data((chunkedHeader + String(repeating: "1\r\nx\r\n", count: 2048) + "0\r\n\r\n").utf8)
        try require(try OTLPRequest.parse(maximumChunks, configuration: config)?.body.count == 2048,
                    "Accept exactly the supported number of chunks")
        let oversizedChunks = Data((chunkedHeader + "\(String(maximumBody.count, radix: 16))\r\n").utf8) +
            maximumBody + Data("\r\n1\r\nx\r\n0\r\n\r\n".utf8)
        do {
            _ = try OTLPRequest.parse(oversizedChunks, configuration: config)
            throw NSError(domain: "TelemetryChecks", code: 7)
        } catch let error as TelemetryError {
            try require(error == .capacity, "Enforce the decoded limit across chunks, not just per chunk")
        }
        let directChunkedHeader = chunkedHeader.replacingOccurrences(of: "/vscodeLocal/v1/traces", with: "/vscodeCopilot")
        let directChunked = try OTLPRequest.parse(Data(directChunkedHeader.utf8) + chunk, configuration: config)
        try require(directChunked?.source == .vscodeCopilot && directChunked?.signal == "traces" && directChunked?.body == data,
                    "Direct Agent Host routing also accepts bounded chunked JSON")
        for (body, expected) in [
            ("z\r\n", TelemetryError.invalid), ("+1\r\nx\r\n0\r\n\r\n", .invalid),
            ("1;extension=value\r\nx\r\n0\r\n\r\n", .unsupported),
            ("1\r\nx!\n0\r\n\r\n", .invalid), ("0\r\n\r\nextra", .invalid),
            ("0\r\nX-Trailer: value\r\n\r\n", .unsupported), ("0\r\n\r\n", .unsupported),
            ("10000000000000000\r\n", .invalid), ("ffffffffffffffff\r\n", .capacity),
            (String(repeating: "1\r\nx\r\n", count: 2049) + "0\r\n\r\n", .capacity)
        ] {
            do {
                _ = try OTLPRequest.parse(Data((chunkedHeader + body).utf8), configuration: config)
                throw NSError(domain: "TelemetryChecks", code: 5)
            } catch let error as TelemetryError {
                try require(error == expected, "Reject malformed or unbounded chunk framing")
            }
        }
        for malformedHeader in [
            chunkedHeader.replacingOccurrences(of: "Transfer-Encoding:", with: "Content-Length: \(data.count)\r\nTransfer-Encoding:"),
            chunkedHeader.replacingOccurrences(of: "chunked", with: "gzip, chunked"),
            chunkedHeader.replacingOccurrences(of: "Transfer-Encoding:", with: "Content-Encoding: gzip\r\nTransfer-Encoding:"),
            chunkedHeader.replacingOccurrences(of: "Transfer-Encoding:", with: "Trailer: digest\r\nTransfer-Encoding:"),
            chunkedHeader.replacingOccurrences(of: "Host: 127.0.0.1", with: "Origin: http://example.invalid")
        ] {
            do {
                _ = try OTLPRequest.parse(Data(malformedHeader.utf8) + chunk, configuration: config)
                throw NSError(domain: "TelemetryChecks", code: 6)
            } catch let error as TelemetryError {
                try require(error == .unsupported, "Do not relax ambiguous framing, compression, trailer or origin guards")
            }
        }
        print("PASS: source-aware telemetry, privacy, disjoint accounting, duplicate exclusion, admission and HTTP limits.")
    }
}
