import Foundation

public enum NoticeCategory: String, Codable, CaseIterable {
    case stopped, failed, usage, incident, recovery, context, attention
}

public struct NoticeTarget: Codable, Equatable {
    public let source: Client
    public let sessionID: String
    public let noticeID: String

    public init(_ notice: SessionNotice) {
        source = notice.source
        sessionID = notice.sessionID
        noticeID = notice.id
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let source = (userInfo["source"] as? String).flatMap(Client.init(rawValue:)),
              let session = userInfo["noticeSessionID"] as? String,
              let notice = userInfo["noticeID"] as? String,
              [session, notice].allSatisfy({
                  $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
              }) else { return nil }
        self.source = source
        sessionID = session
        noticeID = notice
    }

    public var userInfo: [String: String] {
        ["source": source.rawValue, "noticeSessionID": sessionID, "noticeID": noticeID]
    }
}

public struct Notice: Codable, Equatable {
    public let id: String
    public let category: NoticeCategory
    public let title: String
    public let body: String
    public let source: Client?
    public let target: NoticeTarget?
    public let episodeID: String?
    public init(id: String, category: NoticeCategory, title: String, body: String, source: Client? = nil,
                target: NoticeTarget? = nil, episodeID: String? = nil) {
        self.id = id; self.category = category; self.title = title; self.body = body; self.source = source
        self.target = target
        self.episodeID = episodeID
    }
    public static func activity(_ event: ActivityEvent, sessionNotice: SessionNotice? = nil) -> Notice? {
        let target = sessionNotice.map(NoticeTarget.init)
        let id = event.id
        let label = sessionNotice.map { "Session \($0.sessionID.prefix(6)). " } ?? ""
        switch event.kind {
        case .stopped:
            return Notice(id: id, category: .stopped, title: "Copilot execution stopped",
                          body: "\(label)\(event.source.title) reported a stop. This does not establish task success.",
                          source: event.source, target: target)
        case .failed:
            return Notice(id: id, category: .failed, title: "Copilot session ended with an error",
                          body: "\(label)Open session details to review this observation.", source: event.source,
                          target: target, episodeID: sessionNotice?.id)
        case .unrecoverableError:
            return Notice(id: id, category: .failed, title: "Copilot reported an unrecoverable error",
                          body: "\(label)Review the client. This report does not establish that the session ended.",
                          source: event.source, target: target, episodeID: sessionNotice?.id)
        case .inputRequested, .approvalRequested:
            return Notice(id: id, category: .attention,
                          title: event.kind == .inputRequested ? "Copilot requested your input" : "Copilot requested approval",
                          body: "\(label)Open session details. The response status is not observed.",
                          source: event.source, target: target)
        default: return nil
        }
    }
}

public struct NotificationPreferences: Codable, Equatable {
    public var enabled = false
    public var desktop = true
    public var sound = false
    public var expandNotch = false
    public var categories: Set<NoticeCategory> = [.stopped, .failed, .usage, .incident, .recovery]
    public var snoozedUntil: Date?
    public var quietEnabled = false
    public var quietStart = 22 * 60
    public var quietEnd = 8 * 60
    public init() {}

    public func allows(_ category: NoticeCategory, now: Date, managedMute: Bool = false,
                       calendar: Calendar = .current) -> Bool {
        !managedMute && enabled && categories.contains(category)
            && (snoozedUntil.map { now >= $0 } ?? true) && !isQuiet(at: now, calendar: calendar)
    }

    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietEnabled else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard (0..<1440).contains(quietStart), (0..<1440).contains(quietEnd) else { return true }
        if quietStart == quietEnd { return true }
        if quietStart < quietEnd { return minute >= quietStart && minute < quietEnd }
        return minute >= quietStart || minute < quietEnd
    }
}

public struct Delivery: Equatable {
    public let desktop: Bool
    public let sound: Bool
    public let expand: Bool
}

public struct ContextWarningPolicy {
    private struct State {
        var fraction: Double?
        var date: Date
        var armed: Bool
        var warned: Date?
    }
    private var sessions: [String: State] = [:]
    public init() {}
    public mutating func evaluate(_ event: ActivityEvent, now: Date) -> Notice? {
        if event.kind == .contextInvalidated {
            guard event.timestamp > (sessions[event.session]?.date ?? .distantPast) else { return nil }
            sessions[event.session] = State(fraction: nil, date: event.timestamp, armed: false,
                                            warned: sessions[event.session]?.warned)
            prune(now: now)
            return nil
        }
        guard let context = event.context else { return nil }
        prune(now: now)
        guard var state = sessions[event.session] else {
            sessions[event.session] = State(fraction: context.fraction, date: event.timestamp,
                                            armed: context.fraction < 0.8)
            if sessions.count > 100, let first = sessions.min(by: { $0.value.date < $1.value.date }) {
                sessions.removeValue(forKey: first.key)
            }
            return nil
        }
        guard event.timestamp > state.date else { return nil }
        if state.fraction == nil || event.timestamp.timeIntervalSince(state.date) > 300 {
            state.fraction = context.fraction
            state.date = event.timestamp
            state.armed = context.fraction < 0.8
            sessions[event.session] = state
            return nil
        }
        if context.fraction < 0.7 { state.armed = true }
        let crossing = state.armed && (state.fraction ?? 1) < 0.8 && context.fraction >= 0.8
        let notify = crossing && (state.warned.map { event.timestamp.timeIntervalSince($0) >= 600 } ?? true)
        if crossing { state.armed = false }
        if notify { state.warned = event.timestamp }
        state.fraction = context.fraction
        state.date = event.timestamp
        sessions[event.session] = state
        guard notify else { return nil }
        return Notice(id: event.id, category: .context, title: "Copilot context is above 80%",
                      body: "The latest local CLI reading shows high context utilization. This does not predict compaction.",
                      source: .cli)
    }

    private mutating func prune(now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.date) < 86_400 }
        if sessions.count > 100, let first = sessions.min(by: { $0.value.date < $1.value.date }) {
            sessions.removeValue(forKey: first.key)
        }
    }
}

public struct NotificationLedger: Codable {
    public var version = 1
    public private(set) var consumed: [String: Date] = [:]
    public init() {}
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let previous = consumed.count
        consumed = consumed.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }
        return consumed.count != previous
    }

    public mutating func evaluate(_ notice: Notice, preferences: NotificationPreferences,
                                 now: Date, managedMute: Bool = false,
                                 calendar: Calendar = .current) -> Delivery? {
        expire(now: now)
        let ids = Set([notice.id] + [notice.episodeID].compactMap { $0 })
        let duplicate = ids.contains { consumed[$0] != nil }
        for id in ids where consumed[id] == nil { consumed[id] = now }
        while consumed.count > 4096 {
            if let oldest = consumed.min(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }) {
                consumed.removeValue(forKey: oldest.key)
            }
        }
        guard !duplicate else { return nil }
        guard preferences.allows(notice.category, now: now, managedMute: managedMute, calendar: calendar) else { return nil }
        return Delivery(desktop: preferences.desktop, sound: preferences.sound, expand: preferences.expandNotch)
    }
}

/// Future approved observations only. No current integration creates these.
public struct CreditObservation {
    public let account: String
    public let cycle: String
    public let used: Decimal
    public let observedAt: Date
    public let fresh: Bool
    public init(account: String, cycle: String, used: Decimal, observedAt: Date, fresh: Bool) {
        self.account = account; self.cycle = cycle; self.used = used
        self.observedAt = observedAt; self.fresh = fresh
    }
}

public struct TargetRule: Codable {
    public let id: UUID
    public let amount: Decimal
    public let thresholds: [Int]
    public init(amount: Decimal, thresholds: [Int] = [80, 95, 100]) throws {
        var input = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 4, .plain)
        guard !amount.isNaN, amount > 0, rounded == amount,
              !thresholds.isEmpty, thresholds.count <= 10,
              thresholds.allSatisfy({ (1...100).contains($0) }),
              Set(thresholds).count == thresholds.count else { throw TokenotchError.invalidEvent }
        self.id = UUID()
        self.amount = amount
        self.thresholds = thresholds.sorted()
    }
}

public struct TargetLedger: Codable {
    private struct Record: Codable {
        var observedAt: Date
        var consumed: Set<Int>
    }
    private var records: [String: Record] = [:]
    private var baselinedKeys: Set<String> = []
    private enum CodingKeys: String, CodingKey { case records }
    public init() {}
    public init(from decoder: Decoder) throws {
        records = try decoder.container(keyedBy: CodingKeys.self).decode([String: Record].self, forKey: .records)
    }
    public mutating func requireBaseline() { baselinedKeys.removeAll() }

    public mutating func evaluate(_ observation: CreditObservation, rule: TargetRule) -> Int? {
        guard observation.fresh, !observation.account.isEmpty, !observation.cycle.isEmpty,
              !observation.used.isNaN, observation.used >= 0 else { return nil }
        let key = ActivityEvent.digest("\(observation.account):AI-credit:\(observation.cycle):personal:\(rule.id)")
        let crossed = Set(rule.thresholds.filter { observation.used >= rule.amount * Decimal($0) / 100 })
        guard var record = records[key] else {
            records[key] = Record(observedAt: observation.observedAt, consumed: crossed)
            baselinedKeys.insert(key)
            return nil
        }
        guard observation.observedAt > record.observedAt else { return nil }
        let new = crossed.subtracting(record.consumed)
        record.consumed.formUnion(crossed)
        record.observedAt = observation.observedAt
        records[key] = record
        if baselinedKeys.insert(key).inserted { return nil }
        return new.max()
    }
}
