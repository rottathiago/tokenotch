import Foundation

public struct ClaudeSessionEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case started, ended }
    public let version: Int
    public let session: String
    public let kind: Kind
    public let observedAt: Date

    public static func parse(_ data: Data, hook: String, now: Date = Date()) throws -> Self? {
        guard data.count <= HookNormalizer.inputLimit,
              ["SessionStart", "SessionEnd"].contains(hook),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == hook,
              let session = object["session_id"] as? String, !session.isEmpty, session.utf8.count <= 512,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }) else {
            throw TokenotchError.invalidEvent
        }
        if let agent = object["agent_id"], !(agent is NSNull) {
            guard let agent = agent as? String else { throw TokenotchError.invalidEvent }
            if !agent.isEmpty { return nil }
        }
        let value = Self(version: 1, session: ActivityEvent.digest("claudeCode:session:\(session)"),
                         kind: hook == "SessionStart" ? .started : .ended, observedAt: now)
        try value.validate(now: now)
        return value
    }

    public func validate(now: Date) throws {
        guard version == 1, session.count == 64, session.allSatisfy({ "0123456789abcdef".contains($0) }),
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= now.addingTimeInterval(30), observedAt >= now.addingTimeInterval(-120) else {
            throw TokenotchError.invalidEvent
        }
    }
}

public struct ClaudeSessionState {
    private var events: [String: ClaudeSessionEvent] = [:]
    public init() {}
    public var openSessions: Set<String> { Set(events.values.filter { $0.kind == .started }.map(\.session)) }

    public mutating func observe(_ event: ClaudeSessionEvent, now: Date) throws {
        try event.validate(now: now)
        expire(now: now)
        if let previous = events[event.session] {
            guard event.observedAt >= previous.observedAt,
                  event.observedAt != previous.observedAt || previous.kind != .ended else { return }
        }
        guard events[event.session] != nil || events.count < 4096 else { throw TokenotchError.unavailable }
        events[event.session] = event
    }

    public mutating func expire(now: Date) {
        events = events.filter { now.timeIntervalSince($0.value.observedAt) < 86_400 }
    }

    public mutating func stopTracking() {
        events = events.filter { $0.value.kind == .ended }
    }

    public func visible(_ metrics: [ObservedSessionMetrics]) -> [ObservedSessionMetrics] {
        metrics.filter { $0.source != .claudeCLI || events[$0.id]?.kind != .ended }
    }
}
