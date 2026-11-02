import Foundation

public struct ClaudeQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case fiveHour, sevenDay }
    public let kind: Kind
    public let usedPercentage: Double
    public let resetsAt: Date
    public var id: Kind { kind }
    public var title: String { kind == .fiveHour ? "5-hour limit" : "7-day limit" }
    public var fraction: Double { usedPercentage / 100 }

    public func isStale(observedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(observedAt) > 300 || resetsAt <= now
    }

    fileprivate func validate() throws {
        guard usedPercentage.isFinite, (0...100).contains(usedPercentage),
              resetsAt.timeIntervalSince1970.isFinite,
              (1...253_402_300_799).contains(resetsAt.timeIntervalSince1970) else {
            throw TokenotchError.invalidEvent
        }
    }
}

/// Only numeric status-line fields and the provider-scoped session hash cross the bridge.
public struct ClaudeStatusLineSnapshot: Codable, Sendable {
    public let version: Int
    public let session: String
    public let observedAt: Date
    public let context: ContextUsage?
    public let quotas: [ClaudeQuotaWindow]

    public static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= HookNormalizer.inputLimit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String, !session.isEmpty, session.utf8.count <= 512,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }) else {
            throw TokenotchError.invalidEvent
        }
        var context: ContextUsage?
        if let raw = object["context_window"], !(raw is NSNull) {
            guard let window = raw as? [String: Any] else { throw TokenotchError.invalidEvent }
            if let rawUsage = window["current_usage"], !(rawUsage is NSNull) {
                guard let usage = rawUsage as? [String: Any] else { throw TokenotchError.invalidEvent }
                // Match Claude's used_percentage: current input, including both cache buckets, not output.
                let input = try count(usage["input_tokens"])
                let read = try count(usage["cache_read_input_tokens"])
                let write = try count(usage["cache_creation_input_tokens"])
                context = ContextUsage(currentTokens: input + read + write,
                                       tokenLimit: try count(window["context_window_size"]))
                try context?.validate()
            }
        }
        var quotas: [ClaudeQuotaWindow] = []
        if let raw = object["rate_limits"], !(raw is NSNull) {
            guard let limits = raw as? [String: Any] else { throw TokenotchError.invalidEvent }
            for (key, kind) in [("five_hour", ClaudeQuotaWindow.Kind.fiveHour), ("seven_day", .sevenDay)] {
                guard let raw = limits[key], !(raw is NSNull) else { continue }
                guard let window = raw as? [String: Any] else { throw TokenotchError.invalidEvent }
                let quota = ClaudeQuotaWindow(kind: kind, usedPercentage: try number(window["used_percentage"]),
                                             resetsAt: Date(timeIntervalSince1970: try number(window["resets_at"])))
                try quota.validate()
                quotas.append(quota)
            }
        }
        let value = Self(version: 1, session: ActivityEvent.digest("claudeCode:session:\(session)"),
                         observedAt: now, context: context, quotas: quotas)
        try value.validate(now: now)
        return value
    }

    public func validate(now: Date) throws {
        guard version == 1, session.count == 64, session.allSatisfy({ "0123456789abcdef".contains($0) }),
              observedAt.timeIntervalSince1970.isFinite,
              observedAt <= now.addingTimeInterval(30), observedAt >= now.addingTimeInterval(-120),
              quotas.count <= 2, Set(quotas.map(\.kind)).count == quotas.count else {
            throw TokenotchError.invalidEvent
        }
        try context?.validate()
        for quota in quotas { try quota.validate() }
    }

    public var terminalSummary: String {
        let contextLabel = context.map { "Context \(Int(($0.fraction * 100).rounded()))%" } ?? "Context not reported"
        return ([contextLabel] + quotas.map { "\($0.title): \(Int($0.usedPercentage.rounded()))% used" })
            .joined(separator: " | ")
    }

    private static func number(_ raw: Any?) throws -> Double {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { throw TokenotchError.invalidEvent }
        return value.doubleValue
    }

    private static func count(_ raw: Any?) throws -> Int64 {
        let value = try number(raw)
        guard (0...1_000_000_000).contains(value), value.rounded(.towardZero) == value else {
            throw TokenotchError.invalidEvent
        }
        return Int64(value)
    }
}

public struct ClaudeStatusLineState {
    public private(set) var latest: ClaudeStatusLineSnapshot?
    private var sessions: [String: ClaudeStatusLineSnapshot] = [:]
    public init() {}

    public mutating func observe(_ snapshot: ClaudeStatusLineSnapshot, now: Date) throws {
        try snapshot.validate(now: now)
        expire(now: now)
        guard snapshot.observedAt > (sessions[snapshot.session]?.observedAt ?? .distantPast) else { return }
        sessions[snapshot.session] = snapshot
        if snapshot.observedAt > (latest?.observedAt ?? .distantPast) { latest = snapshot }
        if sessions.count > 100, let oldest = sessions.min(by: { $0.value.observedAt < $1.value.observedAt }) {
            sessions.removeValue(forKey: oldest.key)
        }
    }

    public mutating func expire(now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.observedAt) < 86_400 }
        if let latest, now.timeIntervalSince(latest.observedAt) >= 86_400 { self.latest = nil }
    }

    public func merging(_ metrics: [ObservedSessionMetrics], provider: UsageProvider?, source: UsageSource?,
                        now: Date) -> [ObservedSessionMetrics] {
        guard (provider == nil || provider == .claudeCode), (source == nil || source == .claudeCLI) else { return metrics }
        var result = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0) })
        for reading in sessions.values where now.timeIntervalSince(reading.observedAt) < 86_400 {
            let existing = result[reading.session]
            result[reading.session] = ObservedSessionMetrics(id: reading.session, tokens: existing?.tokens,
                context: reading.context.map { ObservedContext(usage: $0, observedAt: reading.observedAt) },
                lastObserved: max(existing?.lastObserved ?? .distantPast, reading.observedAt),
                source: existing?.source ?? .claudeCLI, sessionReported: true,
                sources: (existing?.sources ?? []).union([.claudeCLI]))
        }
        return result.values.sorted { $0.lastObserved == $1.lastObserved ? $0.id < $1.id : $0.lastObserved > $1.lastObserved }
    }
}
