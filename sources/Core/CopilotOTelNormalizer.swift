import CoreFoundation
import Foundation

public struct TelemetryBatch: Sendable {
    public var events: [ActivityEvent] = []
    public var filtered = 0
    public var rejected = 0
    public var unlinked = 0
    public init() {}
}

/// Normalizes only per-call spans. Resource/window identifiers are never session identifiers.
public enum CopilotOTelNormalizer {
    public static let bodyLimit = 4 * 1_048_576
    public static let spanLimit = 2048
    private static let allowedAttributes: Set<String> = [
        "gen_ai.operation.name", "gen_ai.provider.name", "gen_ai.agent.name",
        "gen_ai.conversation.id", "gen_ai.request.model", "gen_ai.response.model",
        "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens",
        "gen_ai.usage.cache_read.input_tokens", "gen_ai.usage.cache_creation.input_tokens",
        "copilot_chat.time_to_first_token"
    ]

    public static func decode(_ data: Data, source: UsageSource, now: Date = Date(),
                              importing: Bool = false) throws -> TelemetryBatch {
        guard source != .cli, data.count <= bodyLimit else { throw TelemetryError.capacity }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = root["resourceSpans"] as? [[String: Any]],
              resources.count <= spanLimit else { throw TelemetryError.unsupported }
        var result = TelemetryBatch()
        var count = 0
        for resource in resources {
            let values = try attributes((resource["resource"] as? [String: Any])?["attributes"],
                                        keys: ["service.name", "service.namespace"])
            let service = values["service.name"] as? String
            let namespace = values["service.namespace"] as? String
            guard let scopes = resource["scopeSpans"] as? [[String: Any]],
                  scopes.count <= spanLimit else { throw TelemetryError.invalid }
            for scope in scopes {
                guard let spans = scope["spans"] as? [[String: Any]] else { throw TelemetryError.invalid }
                count += spans.count
                guard count <= spanLimit else { throw TelemetryError.capacity }
                for span in spans {
                    do {
                        let attrs = try attributes(span["attributes"], keys: allowedAttributes)
                        guard attrs["gen_ai.operation.name"] as? String == "chat" else {
                            result.filtered += 1
                            continue
                        }
                        // A terminal CLI can inherit Local Chat's exporter. It is already counted by the CLI extension.
                        if source == .vscodeLocal && service == "github-copilot" {
                            result.filtered += 1
                            continue
                        }
                        guard (source == .vscodeLocal && service == "copilot-chat") ||
                              (source == .vscodeCopilot && service == "github-copilot") else {
                            result.rejected += 1
                            continue
                        }
                        if importing && source == .vscodeCopilot && namespace != "vscode.agent-host" {
                            throw TelemetryError.unsupported
                        }
                        guard attrs["gen_ai.provider.name"] as? String == "github" else {
                            result.filtered += 1
                            continue
                        }
                        if let agent = attrs["gen_ai.agent.name"] as? String,
                           !["copilot", "GitHub Copilot Chat", "copilotcli"].contains(agent) {
                            result.filtered += 1
                            continue
                        }
                        let event = try normalize(span, attributes: attrs, source: source, now: now)
                        if !importing && event.timestamp <= now.addingTimeInterval(-86_400) {
                            throw TelemetryError.invalid
                        }
                        result.events.append(event)
                        if event.metricSessionReported == false { result.unlinked += 1 }
                    } catch {
                        result.rejected += 1
                    }
                }
            }
        }
        return result
    }

    private static func normalize(_ span: [String: Any], attributes attrs: [String: Any],
                                  source: UsageSource, now: Date) throws -> ActivityEvent {
        guard let trace = span["traceId"] as? String, validHex(trace, count: 32),
              let id = span["spanId"] as? String, validHex(id, count: 16) else { throw TelemetryError.invalid }
        let start = try time(span["startTimeUnixNano"])
        let end = try time(span["endTimeUnixNano"])
        guard start <= end, end <= now.addingTimeInterval(30),
              end.timeIntervalSince(start) <= 86_400 else { throw TelemetryError.invalid }
        let input = try number(attrs["gen_ai.usage.input_tokens"])
        let output = try number(attrs["gen_ai.usage.output_tokens"])
        let read = try attrs["gen_ai.usage.cache_read.input_tokens"].map(number)
        let write = try attrs["gen_ai.usage.cache_creation.input_tokens"].map(number)
        guard (read ?? 0) + (write ?? 0) <= input else { throw TelemetryError.invalid }
        let model = attrs["gen_ai.response.model"] ?? attrs["gen_ai.request.model"]
        guard model == nil || model is String else { throw TelemetryError.invalid }
        let conversation = attrs["gen_ai.conversation.id"] as? String
        if let conversation {
            guard !conversation.isEmpty, conversation.utf8.count <= 512 else { throw TelemetryError.invalid }
        }
        let call = ActivityEvent.digest("otel:\(source.rawValue):\(trace):\(id)")
        let session = ActivityEvent.digest("otel:\(source.rawValue):\(conversation ?? "unlinked:\(trace):\(id)")")
        let latency: Double?
        if let value = attrs["copilot_chat.time_to_first_token"] {
            if let text = value as? String {
                guard let value = Int64(text), TokenUsage.validLatency(Double(value)) else { throw TelemetryError.invalid }
                latency = Double(value)
            } else {
                guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      TokenUsage.validLatency(value.doubleValue) else { throw TelemetryError.invalid }
                latency = value.doubleValue
            }
        } else { latency = nil }
        let tokens = TokenUsage(callID: call, input: input - (read ?? 0) - (write ?? 0), output: output,
                                cacheInput: read ?? 0, cacheInputReported: read != nil, model: model as? String,
                                durationMs: end.timeIntervalSince(start) * 1000, timeToFirstTokenMs: latency,
                                cacheWrite: write ?? 0, cacheWriteReported: write != nil)
        let event = ActivityEvent(source: .vscode, session: session, kind: .usage, timestamp: end,
                                  tokens: tokens, metricSource: source, metricSessionReported: conversation != nil)
        try event.validatePayload()
        return event
    }

    public static func validHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) } && text.contains { $0 != "0" }
    }

    private static func time(_ raw: Any?) throws -> Date {
        guard let text = raw as? String, text.count <= 20, text.allSatisfy(\.isNumber),
              let nanos = UInt64(text), nanos > 0 else { throw TelemetryError.invalid }
        return Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
    }

    private static func number(_ raw: Any?) throws -> Int64 {
        if let text = raw as? String {
            guard !text.isEmpty, text.count <= 10, text.allSatisfy(\.isNumber),
                  let value = Int64(text), (0...1_000_000_000).contains(value) else { throw TelemetryError.invalid }
            return value
        }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              (0...1_000_000_000).contains(value.doubleValue) else { throw TelemetryError.invalid }
        return value.int64Value
    }

    private static func attributes(_ raw: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let entries = raw as? [[String: Any]], entries.count <= 512 else { throw TelemetryError.invalid }
        var result: [String: Any] = [:]
        for entry in entries {
            guard let key = entry["key"] as? String else { throw TelemetryError.invalid }
            guard keys.contains(key) else { continue }
            guard result[key] == nil, let value = entry["value"] as? [String: Any], value.count == 1 else {
                throw TelemetryError.invalid
            }
            if key.hasPrefix("gen_ai.usage.") || key == "copilot_chat.time_to_first_token" {
                guard value["stringValue"] == nil else { throw TelemetryError.invalid }
            }
            if let text = value["stringValue"] as? String { result[key] = text }
            else if let number = value["intValue"] { result[key] = number }
            else if let number = value["doubleValue"] { result[key] = number }
            else { throw TelemetryError.invalid }
        }
        return result
    }
}
