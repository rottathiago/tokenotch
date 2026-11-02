import CoreFoundation
import Foundation

public enum ClaudeCodeRejectionStage: String, Error, Sendable {
    case eventMarker, producer, entrypoint, remoteSession, requestIdentity, sessionIdentity, timestamp, tokens, duration, cost, payload

    public var title: String {
        switch self {
        case .eventMarker: return "Conflicting event identity"
        case .producer: return "Unrecognized Claude telemetry producer"
        case .entrypoint: return "Unsupported or invalid launch metadata"
        case .remoteSession: return "Cloud-session marker reported"
        case .requestIdentity: return "Missing or invalid server request ID"
        case .sessionIdentity: return "Invalid session ID"
        case .timestamp: return "Missing, invalid or expired event timestamp"
        case .tokens: return "Missing or invalid token counts"
        case .duration: return "Invalid call duration"
        case .cost: return "Invalid estimated cost"
        case .payload: return "Malformed usage fields"
        }
    }

    public var explanation: String {
        switch self {
        case .requestIdentity:
            return "Claude reported a missing or invalid server request ID. Those calls cannot be counted safely without a stable identity; restarting alone may not resolve this client compatibility issue."
        case .producer:
            return "Claude reported an unrecognized telemetry producer. Only local Claude Code CLI usage is collected."
        case .entrypoint:
            return "Claude reported unsupported or invalid launch metadata. Only terminal Claude Code CLI sessions are collected; SDK and editor producers are excluded."
        case .remoteSession:
            return "Claude included a cloud-session marker (ccr.session.id), so those observations are excluded. Only local Claude Code CLI sessions are collected."
        case .timestamp:
            return "Claude reported a missing, invalid or expired event timestamp. Check the system clock and start a new session after setup."
        default:
            return "Claude usage was rejected: \(title.lowercased()). No missing values were invented. Review the rejection counts in Coverage and privacy."
        }
    }
}

public enum ClaudeCodeEventMarker: String, Sendable {
    case apiAttribute, namespacedAPIAttribute, apiBody, shortAPIBody, other
}

public enum ClaudeCodeOTelNormalizer {
    public static let bodyLimit = 4 * 1_048_576
    public static let recordLimit = 2048
    private static let keys: Set<String> = [
        "event.name", "event.timestamp", "session.id", "request_id", "app.entrypoint",
        "ccr.session.id", "model", "input_tokens", "output_tokens", "cache_read_tokens",
        "cache_creation_tokens", "duration_ms", "cost_usd_micros", "cost_usd"
    ]

    public static func decode(_ data: Data, now: Date = Date()) throws -> TelemetryBatch {
        guard data.count <= bodyLimit else { throw TelemetryError.capacity }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TelemetryError.unsupported
            }
            root = object
        } catch let error as TelemetryError { throw error }
        catch { throw TelemetryError.invalid }
        guard root["resourceSpans"] == nil, root["resourceMetrics"] == nil,
              let resources = root["resourceLogs"] as? [[String: Any]],
              resources.count <= recordLimit else { throw TelemetryError.unsupported }
        var batch = TelemetryBatch()
        var count = 0
        for resource in resources {
            let resourceAttributes = try attributes((resource["resource"] as? [String: Any])?["attributes"],
                keys: ["service.name", "app.entrypoint", "ccr.session.id"])
            guard let scopes = resource["scopeLogs"] as? [[String: Any]], scopes.count <= recordLimit else {
                throw TelemetryError.invalid
            }
            for scope in scopes {
                guard let records = scope["logRecords"] as? [[String: Any]] else { throw TelemetryError.invalid }
                count += records.count
                guard count <= recordLimit else { throw TelemetryError.capacity }
                for record in records {
                    if resourceAttributes["service.name"] as? String == "claude-code-desktop" {
                        batch.filtered += 1
                        continue
                    }
                    var stage = ClaudeCodeRejectionStage.eventMarker
                    do {
                        let marker = try attributes(record["attributes"], keys: ["event.name"])
                        let name = marker["event.name"] as? String
                        let body = record["body"] as? [String: Any]
                        let bodyName = body?["stringValue"] as? String
                        let eventMarker: ClaudeCodeEventMarker
                        if name == "api_request" { eventMarker = .apiAttribute }
                        else if name == "claude_code.api_request" { eventMarker = .namespacedAPIAttribute }
                        else if bodyName == "claude_code.api_request" { eventMarker = .apiBody }
                        else if bodyName == "api_request" { eventMarker = .shortAPIBody }
                        else { eventMarker = .other }
                        batch.claudeEventMarkers[eventMarker, default: 0] += 1
                        if let name {
                            guard name == "api_request" else {
                                if bodyName == "claude_code.api_request" { throw TelemetryError.invalid }
                                batch.filtered += 1
                                continue
                            }
                            if let bodyName, bodyName.hasPrefix("claude_code."),
                               bodyName != "claude_code.api_request" { throw TelemetryError.invalid }
                        } else {
                            guard marker["event.name"] == nil else { throw TelemetryError.invalid }
                            guard body?.count == 1, bodyName == "claude_code.api_request" else {
                                batch.filtered += 1
                                continue
                            }
                        }
                        stage = .payload
                        let values = try attributes(record["attributes"], keys: keys)
                        stage = .producer
                        let source = try source(resource: resourceAttributes, event: values)
                        stage = .requestIdentity
                        guard let request = try identifier(values["request_id"]) else {
                            batch.unidentified += 1
                            batch.rejected += 1
                            batch.claudeRejections[stage, default: 0] += 1
                            continue
                        }
                        let call = ActivityEvent.digest("claudeCode:request:\(request)")
                        stage = .sessionIdentity
                        let session = try identifier(values["session.id"])
                        stage = .timestamp
                        let time = try timestamp(values["event.timestamp"])
                        guard time <= now.addingTimeInterval(30), time > now.addingTimeInterval(-86_400) else {
                            throw TelemetryError.invalid
                        }
                        stage = .tokens
                        let input = try integer(values["input_tokens"], limit: 1_000_000_000)
                        let output = try integer(values["output_tokens"], limit: 1_000_000_000)
                        let read = try values["cache_read_tokens"].map { try integer($0, limit: 1_000_000_000) }
                        let write = try values["cache_creation_tokens"].map { try integer($0, limit: 1_000_000_000) }
                        stage = .payload
                        let model = values["model"]
                        guard model == nil || model is String else { throw TelemetryError.invalid }
                        stage = .duration
                        let duration = try values["duration_ms"].map(latency)
                        stage = .cost
                        let estimatedCost = try cost(values)
                        let tokens = TokenUsage(callID: call,
                            input: input, output: output,
                            cacheInput: read ?? 0, cacheInputReported: read != nil, model: model as? String,
                            durationMs: duration,
                            cacheWrite: write ?? 0, cacheWriteReported: write != nil,
                            estimatedCostMicros: estimatedCost)
                        let event = ActivityEvent(source: source.client,
                            session: ActivityEvent.digest("claudeCode:session:\(session ?? "unlinked:\(call)")"),
                            kind: .usage, timestamp: time, tokens: tokens, metricSource: source,
                            metricSessionReported: session != nil)
                        stage = .payload
                        try event.validatePayload()
                        batch.events.append(event)
                        if session == nil { batch.unlinked += 1 }
                    } catch let reason as ClaudeCodeRejectionStage {
                        batch.unattributed += 1
                        batch.rejected += 1
                        batch.claudeRejections[reason, default: 0] += 1
                    } catch TelemetryError.unsupported {
                        batch.unattributed += 1
                        batch.rejected += 1
                        batch.claudeRejections[stage, default: 0] += 1
                    } catch {
                        batch.rejected += 1
                        batch.claudeRejections[stage, default: 0] += 1
                    }
                }
            }
        }
        return batch
    }

    private static func source(resource: [String: Any], event: [String: Any]) throws -> UsageSource {
        guard resource["ccr.session.id"] == nil, event["ccr.session.id"] == nil else {
            throw ClaudeCodeRejectionStage.remoteSession
        }
        let resourceEntry = resource["app.entrypoint"] as? String
        let eventEntry = event["app.entrypoint"] as? String
        guard resource["app.entrypoint"] == nil || resourceEntry != nil,
              event["app.entrypoint"] == nil || eventEntry != nil else {
            throw ClaudeCodeRejectionStage.entrypoint
        }
        switch resource["service.name"] as? String {
        case "claude-code":
            guard (eventEntry ?? resourceEntry) == "cli",
                  resourceEntry == nil || eventEntry == nil || resourceEntry == eventEntry else {
                throw ClaudeCodeRejectionStage.entrypoint
            }
            return .claudeCLI
        default: throw ClaudeCodeRejectionStage.producer
        }
    }

    private static func identifier(_ raw: Any?) throws -> String? {
        guard let raw else { return nil }
        guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 512,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }) else {
            throw TelemetryError.invalid
        }
        return text
    }

    private static func timestamp(_ raw: Any?) throws -> Date {
        guard let text = raw as? String, text.utf8.count <= 64 else { throw TelemetryError.invalid }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let time = formatter.date(from: text) { return time }
        formatter.formatOptions = [.withInternetDateTime]
        guard let time = formatter.date(from: text) else { throw TelemetryError.invalid }
        return time
    }

    private static func integer(_ raw: Any?, limit: Int64) throws -> Int64 {
        if let text = raw as? String {
            guard !text.isEmpty, text.utf8.count <= 19,
                  text.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int64(text), (0...limit).contains(value) else { throw TelemetryError.invalid }
            return value
        }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(limit) else { throw TelemetryError.invalid }
        return number.int64Value
    }

    private static func latency(_ raw: Any) throws -> Double {
        let value: Double
        if let text = raw as? String, text.utf8.count <= 32, let number = Double(text) { value = number }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
        else { throw TelemetryError.invalid }
        guard TokenUsage.validLatency(value) else { throw TelemetryError.invalid }
        return value
    }

    private static func cost(_ values: [String: Any]) throws -> Int64? {
        if let micros = values["cost_usd_micros"] {
            return try integer(micros, limit: EstimatedCostCoverage.perCallLimit)
        }
        guard let raw = values["cost_usd"] else { return nil }
        let text: String
        if let value = raw as? String {
            guard value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  value.filter({ $0 == "." }).count <= 1 else { throw TelemetryError.invalid }
            text = value
        }
        else if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                value.doubleValue.isFinite { text = value.stringValue }
        else { throw TelemetryError.invalid }
        guard !text.isEmpty, text.utf8.count <= 32, text.contains(where: \.isNumber),
              let dollars = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !dollars.isNaN, dollars >= 0,
              dollars <= Decimal(EstimatedCostCoverage.perCallLimit) / 1_000_000 else { throw TelemetryError.invalid }
        var value = dollars * 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard !rounded.isNaN, rounded >= 0, rounded <= Decimal(EstimatedCostCoverage.perCallLimit) else {
            throw TelemetryError.invalid
        }
        return NSDecimalNumber(decimal: rounded).int64Value
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
            if key == "app.entrypoint" {
                guard value["stringValue"] is String else { throw TelemetryError.invalid }
            }
            if let text = value["stringValue"] as? String { result[key] = text }
            else if let number = value["intValue"] { result[key] = number }
            else if let number = value["doubleValue"] { result[key] = number }
            else { throw TelemetryError.invalid }
        }
        return result
    }
}
