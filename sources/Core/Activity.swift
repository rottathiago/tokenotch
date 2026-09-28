import CryptoKit
import Foundation

public enum Client: String, Codable, CaseIterable, Identifiable, Sendable {
    case cli, vscode
    public var id: String { rawValue }
    public var title: String { self == .cli ? "Copilot CLI" : "VS Code (Preview)" }
    public var bundleID: String { self == .cli ? "com.apple.Terminal" : "com.microsoft.VSCode" }
}

public enum EventKind: String, Codable, Sendable {
    case started, working, stopped, ended, failed, cancelled, usage, context, contextInvalidated, compaction, active, idle
    case inputRequested, approvalRequested, unrecoverableError

    public var isMetric: Bool { self == .usage || self == .context || self == .contextInvalidated || self == .compaction }
    public var isAttention: Bool { self == .inputRequested || self == .approvalRequested || self == .unrecoverableError }
    public var isActivitySnapshot: Bool { self == .active || self == .idle }
    public var reportsWork: Bool { self == .working || self == .active }

    var order: Int {
        switch self {
        case .started: return 0
        case .working, .active: return 1
        case .idle: return 2
        case .stopped: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .failed: return 6
        case .usage, .context, .contextInvalidated, .compaction, .inputRequested, .approvalRequested, .unrecoverableError: return -1
        }
    }
}

public struct ActivityEvent: Codable, Equatable, Sendable {
    public let version: Int
    public let source: Client
    public let session: String
    public let kind: EventKind
    public let timestamp: Date
    public let tokens: TokenUsage?
    public let context: ContextUsage?
    public let compaction: CompactionUsage?
    public let metricID: String?
    public let metricSource: UsageSource?
    public let metricSessionReported: Bool?
    public var usageSource: UsageSource { metricSource ?? .cli }
    public var id: String {
        Self.digest("\(source.rawValue):\(session):\(kind.rawValue):\(tokens?.callID ?? metricID ?? ""):\(timestamp.timeIntervalSince1970)")
    }

    public init(source: Client, session: String, kind: EventKind, timestamp: Date,
                tokens: TokenUsage? = nil, context: ContextUsage? = nil,
                compaction: CompactionUsage? = nil, metricID: String? = nil,
                metricSource: UsageSource? = nil, metricSessionReported: Bool? = nil) {
        version = metricSource != nil ? 4 : (kind.isAttention ? 3 : (kind == .compaction || kind == .contextInvalidated || kind.isActivitySnapshot ? 2 : 1))
        self.source = source
        self.session = session
        self.kind = kind
        self.timestamp = timestamp
        self.tokens = tokens
        self.context = context
        self.compaction = compaction
        self.metricID = metricID
        self.metricSource = metricSource
        self.metricSessionReported = metricSessionReported
    }
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func validate(now: Date) throws {
        try validatePayload()
        guard timestamp <= now.addingTimeInterval(30),
              timestamp >= now.addingTimeInterval(-120) else { throw TokenotchError.invalidEvent }
    }

    public func validatePayload() throws {
        guard (1...4).contains(version), session.count == 64,
              session.allSatisfy({ "0123456789abcdef".contains($0) }),
              timestamp.timeIntervalSince1970.isFinite else { throw TokenotchError.invalidEvent }
        guard (version == 4) == (metricSource != nil),
              metricSource != nil || metricSessionReported == nil,
              metricSource == nil || (source == .vscode && kind == .usage && metricSource != .cli)
        else { throw TokenotchError.invalidEvent }
        guard (version == 3) == kind.isAttention,
              !kind.isAttention || source == .cli else { throw TokenotchError.invalidEvent }
        if kind.isActivitySnapshot {
            guard version == 2, source == .cli else { throw TokenotchError.invalidEvent }
        }
        if let metricID {
            guard metricID.count == 64, metricID.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw TokenotchError.invalidEvent
            }
        }
        if kind == .usage {
            guard (source == .cli || metricSource != nil), let tokens, context == nil, compaction == nil else { throw TokenotchError.invalidEvent }
            try tokens.validate()
        } else if kind == .context {
            guard source == .cli, let context, tokens == nil, compaction == nil else { throw TokenotchError.invalidEvent }
            try context.validate()
        } else if kind == .contextInvalidated {
            guard version == 2, source == .cli, tokens == nil, context == nil,
                  compaction == nil, metricID != nil else { throw TokenotchError.invalidEvent }
        } else if kind == .compaction {
            guard version == 2, source == .cli, tokens == nil, context == nil,
                  metricID != nil, let compaction else { throw TokenotchError.invalidEvent }
            try compaction.validate()
        } else if tokens != nil || context != nil || compaction != nil || metricID != nil { throw TokenotchError.invalidEvent }
    }
}

public enum TokenotchError: String, Error, LocalizedError {
    case metricUpgrade = "Token integration needs updating. In Connections, use Copilot CLI > Options > Review or repair setup, then reload extensions or restart CLI sessions."
    case invalidEvent = "Unsupported, missing, oversized or expired hook fields."
    case unsafePath = "An integration path is not an owned, private regular file or directory."
    case bridgeUnavailable = "The local Tokenotch bridge is unavailable."
    case storage = "Tokenotch could not save local state. Notifications are paused."
    case ownership = "This hook file was changed or is not owned by Tokenotch. It was left untouched."
    case unavailable = "This capability is currently unavailable. Check its connection and setup status."
    public var errorDescription: String? { rawValue }
}

public enum HookNormalizer {
    public static let inputLimit = 65_536

    public static func normalize(_ data: Data, source: Client, hook: String,
                                 now: Date = Date()) throws -> ActivityEvent {
        guard let event = try normalizeObservation(data, source: source, hook: hook, now: now) else {
            throw TokenotchError.invalidEvent
        }
        return event
    }

    /// A nil observation is a valid filtered hook, not a delivery failure.
    public static func normalizeObservation(_ data: Data, source: Client, hook: String,
                                            now: Date = Date()) throws -> ActivityEvent? {
        guard data.count <= inputLimit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenotchError.invalidEvent
        }
        // Local VS Code can discover CLI hook files, but its dedicated adapter owns those observations.
        if source == .cli, object["sessionId"] == nil, object["session_id"] is String,
           object["timestamp"] is String {
            let localEvents = ["sessionStart": "SessionStart", "userPromptSubmitted": "UserPromptSubmit", "agentStop": "Stop"]
            if let expected = localEvents[hook], object["hook_event_name"] as? String == expected { return nil }
        }
        let sessionKey = source == .cli ? "sessionId" : "session_id"
        guard let session = object[sessionKey] as? String,
              !session.isEmpty, session.utf8.count <= 512 else { throw TokenotchError.invalidEvent }
        let timestamp: Date
        let kind: EventKind
        var tokens: TokenUsage?
        var context: ContextUsage?
        var compaction: CompactionUsage?
        var metricID: String?
        if source == .cli {
            guard let number = object["timestamp"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { throw TokenotchError.invalidEvent }
            timestamp = Date(timeIntervalSince1970: number.doubleValue / 1000)
            guard timestamp.timeIntervalSince1970.isFinite,
                  timestamp <= now.addingTimeInterval(30),
                  timestamp >= now.addingTimeInterval(-120) else { throw TokenotchError.invalidEvent }
            switch hook {
            case "notification":
                guard object["hook_event_name"] as? String == "Notification",
                      let type = object["notification_type"] as? String,
                      !type.isEmpty, type.utf8.count <= 128 else { throw TokenotchError.invalidEvent }
                switch type {
                case "elicitation_dialog": kind = .inputRequested
                case "permission_prompt": kind = .approvalRequested
                default: return nil
                }
            case "errorOccurred":
                guard let recoverable = object["recoverable"] as? NSNumber,
                      CFGetTypeID(recoverable) == CFBooleanGetTypeID() else { throw TokenotchError.invalidEvent }
                if recoverable.boolValue { return nil }
                kind = .unrecoverableError
            case "activity":
                guard let active = object["active"] as? NSNumber,
                      CFGetTypeID(active) == CFBooleanGetTypeID() else { throw TokenotchError.invalidEvent }
                kind = active.boolValue ? .active : .idle
            case "usage":
                guard let contract = object["usageContract"] as? NSNumber,
                      CFGetTypeID(contract) != CFBooleanGetTypeID(),
                      contract == 1 else { throw TokenotchError.metricUpgrade }
                guard let call = object["eventId"] as? String, !call.isEmpty, call.count <= 512 else {
                    throw TokenotchError.invalidEvent
                }
                let model: String?
                if let value = object["model"] {
                    guard let name = value as? String else { throw TokenotchError.invalidEvent }
                    model = name
                } else { model = nil }
                let cacheReported: Bool?
                if let value = object["cacheReadTokensReported"] {
                    guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                          flag.boolValue == (object["cacheReadTokens"] != nil) else {
                        throw TokenotchError.invalidEvent
                    }
                    cacheReported = flag.boolValue
                } else { cacheReported = nil }
                let writeReported: Bool?
                if let value = object["cacheWriteTokensReported"] {
                    guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                          flag.boolValue == (object["cacheWriteTokens"] != nil) else {
                        throw TokenotchError.invalidEvent
                    }
                    writeReported = flag.boolValue
                } else { writeReported = nil }
                let inclusiveInput = try tokenCount(object["inputTokens"])
                let reads = try object["cacheReadTokens"].map(tokenCount) ?? 0
                let writes = try object["cacheWriteTokens"].map(tokenCount) ?? 0
                guard reads + writes <= inclusiveInput else { throw TokenotchError.invalidEvent }
                // Copilot CLI's input is inclusive; downstream consumers sum disjoint buckets.
                tokens = TokenUsage(callID: ActivityEvent.digest("\(session):\(call)"),
                                    input: inclusiveInput - reads - writes,
                                    output: try tokenCount(object["outputTokens"]),
                                    cacheInput: reads,
                                    cacheInputReported: cacheReported,
                                    model: model,
                                    durationMs: try optionalLatency(object["durationMs"]),
                                    timeToFirstTokenMs: try optionalLatency(object["timeToFirstTokenMs"]),
                                    cacheWrite: writes, cacheWriteReported: writeReported)
                kind = .usage
            case "context", "contextInvalidated":
                if let value = object["eventId"] {
                    guard let call = value as? String, !call.isEmpty, call.count <= 512 else {
                        throw TokenotchError.invalidEvent
                    }
                    metricID = ActivityEvent.digest("\(session):context:\(call)")
                }
                if hook == "contextInvalidated" {
                    guard metricID != nil, object["currentTokens"] == nil, object["tokenLimit"] == nil else {
                        throw TokenotchError.invalidEvent
                    }
                    kind = .contextInvalidated
                } else {
                    context = ContextUsage(currentTokens: try tokenCount(object["currentTokens"]),
                                           tokenLimit: try tokenCount(object["tokenLimit"]))
                    kind = .context
                }
            case "compaction":
                guard let call = object["eventId"] as? String, !call.isEmpty, call.count <= 512,
                      let phase = object["phase"] as? String, ["start", "complete"].contains(phase) else {
                    throw TokenotchError.invalidEvent
                }
                let success: Bool?
                if phase == "complete" {
                    guard let number = object["success"] as? NSNumber,
                          CFGetTypeID(number) == CFBooleanGetTypeID() else { throw TokenotchError.invalidEvent }
                    success = number.boolValue
                } else {
                    guard object["success"] == nil else { throw TokenotchError.invalidEvent }
                    success = nil
                }
                compaction = CompactionUsage(success: success,
                    before: try object["beforeTokens"].map(tokenCount),
                    after: try object["afterTokens"].map(tokenCount))
                metricID = ActivityEvent.digest("\(session):compaction:\(call)")
                kind = .compaction
            case "sessionStart": kind = .started
            case "userPromptSubmitted": kind = .working
            case "agentStop":
                guard object["stopReason"] as? String == "end_turn" else { throw TokenotchError.invalidEvent }
                kind = .stopped
            case "sessionEnd":
                switch object["reason"] as? String {
                case "error": kind = .failed
                case "abort": kind = .cancelled
                case "complete", "user_exit", "timeout": kind = .ended
                // A timeout is not evidence that the task failed.
                default: throw TokenotchError.invalidEvent
                }
            default: throw TokenotchError.invalidEvent
            }
        } else {
            guard object["hook_event_name"] as? String == hook,
                  let text = object["timestamp"] as? String,
                  let date = isoDate(text) else { throw TokenotchError.invalidEvent }
            timestamp = date
            switch hook {
            case "SessionStart": kind = .started
            case "UserPromptSubmit": kind = .working
            case "Stop": kind = .stopped
            default: throw TokenotchError.invalidEvent
            }
        }
        let event = ActivityEvent(source: source, session: ActivityEvent.digest(session),
                                  kind: kind, timestamp: timestamp, tokens: tokens, context: context,
                                  compaction: compaction, metricID: metricID)
        try event.validate(now: now)
        return event
    }

    private static func tokenCount(_ value: Any?) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1_000_000_000).contains(number.doubleValue),
              number.doubleValue.rounded() == number.doubleValue else { throw TokenotchError.invalidEvent }
        return number.int64Value
    }

    private static func optionalLatency(_ value: Any?) throws -> Double? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              TokenUsage.validLatency(number.doubleValue) else { throw TokenotchError.invalidEvent }
        return number.doubleValue
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public struct ObservedSession: Identifiable, Equatable {
    public let source: Client
    public let key: String
    public var kind: EventKind
    public var observedAt: Date
    public var workStartedAt: Date?
    public var id: String { "\(source.rawValue):\(key)" }
    public func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(observedAt) <= (kind.isActivitySnapshot ? 90 : 300)
    }
    public func isWorking(now: Date) -> Bool {
        kind.reportsWork && isFresh(now: now)
    }
    public func hasMissingActivity(now: Date) -> Bool {
        [.started, .working, .active, .idle].contains(kind) && !isFresh(now: now)
    }
    public func label(now: Date) -> String {
        if hasMissingActivity(now: now) { return "No recent activity updates" }
        switch kind {
        case .started: return "Session observed"
        case .working: return "Working (last reported)"
        case .active: return "Working (live)"
        case .idle: return "Idle (live)"
        case .stopped: return "Execution stopped"
        case .ended: return "Session ended"
        case .failed: return "Session ended with an error"
        case .cancelled: return "Session cancelled"
        case .usage: return "Usage observed"
        case .context: return "Context observed"
        case .contextInvalidated: return "Context awaiting a new reading"
        case .compaction: return "Compaction observed"
        case .inputRequested: return "Input requested (last reported)"
        case .approvalRequested: return "Approval requested (last reported)"
        case .unrecoverableError: return "Unrecoverable error reported"
        }
    }
}

public struct ActivityState {
    public private(set) var sessions: [String: ObservedSession] = [:]
    public init() {}
    public mutating func expire(now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.observedAt) < 86_400 }
    }
    public mutating func remove(_ source: Client) {
        sessions = sessions.filter { $0.value.source != source }
    }
    public mutating func accept(_ event: ActivityEvent, now: Date) throws -> Bool {
        try event.validate(now: now)
        guard !event.kind.isMetric, !event.kind.isAttention else { throw TokenotchError.invalidEvent }
        let key = "\(event.source.rawValue):\(event.session)"
        let previous = sessions[key]
        if let previous {
            if previous.observedAt > event.timestamp { return false }
            if previous.observedAt == event.timestamp && previous.kind.order >= event.kind.order { return false }
            // An idle snapshot is not a new lifecycle transition or a replacement for a known outcome.
            if event.kind == .idle && [.ended, .cancelled, .failed].contains(previous.kind) { return false }
        }
        let workStartedAt: Date?
        if event.kind == .working || (event.kind == .active && previous?.kind.reportsWork != true) {
            workStartedAt = event.timestamp
        } else {
            workStartedAt = previous?.workStartedAt
        }
        expire(now: now)
        sessions[key] = ObservedSession(source: event.source, key: event.session,
                                        kind: event.kind, observedAt: event.timestamp, workStartedAt: workStartedAt)
        if sessions.count > 100, let oldest = sessions.min(by: { $0.value.observedAt < $1.value.observedAt }) {
            sessions.removeValue(forKey: oldest.key)
        }
        return true
    }
}
