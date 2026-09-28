import CryptoKit
import Foundation

public enum SessionNoticeKind: String, Codable, CaseIterable {
    case error, input, approval, compaction, context, stopped

    public var isRequest: Bool { self == .input || self == .approval }

    public init?(eventKind: EventKind) {
        switch eventKind {
        case .inputRequested: self = .input
        case .approvalRequested: self = .approval
        case .unrecoverableError, .failed: self = .error
        case .stopped: self = .stopped
        default: return nil
        }
    }

    public var priority: Int {
        switch self {
        case .error: return 0
        case .input, .approval: return 1
        case .compaction: return 2
        case .context: return 3
        case .stopped: return 4
        }
    }

    public var title: String {
        switch self {
        case .error: return "Session reported an error"
        case .input: return "Input requested"
        case .approval: return "Approval requested"
        case .compaction: return "Compaction failed"
        case .context: return "High context reported"
        case .stopped: return "Execution stopped"
        }
    }
}

public enum SessionNoticeDisposition: String, Codable {
    case pending, resolved, superseded, dismissed
}

public struct SessionNotice: Codable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let source: Client
    public let kind: SessionNoticeKind
    public let began: Date
    public var observedAt: Date
    public var viewedAt: Date?
    public var disposition: SessionNoticeDisposition = .pending

    public var needsHighlight: Bool {
        disposition == .pending && (kind != .stopped || viewedAt == nil)
    }

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(observedAt) > 300
    }
}

public enum SessionAttentionError: Error, LocalizedError {
    case invalidStorage
    public var errorDescription: String? { "Saved session notices are invalid or use an unsupported format." }
}

public struct SessionAttentionState: Codable, Equatable {
    private struct Record: Codable, Equatable {
        var source: Client
        var notices: [String: SessionNotice] = [:]
        var lifecycleAt: Date?
        var lifecycle: EventKind?
        var contextAt: Date?
        var compactionAt: Date?
        var compactionCompleted = false
        var workBoundary: Date?
        var updatedAt: Date
    }

    public static let sessionLimit = 100
    public static let receiptLimit = 4096
    private var version = 2
    private var key: Data
    private var records: [String: Record] = [:]
    private var receipts: [String: Date] = [:]
    // Limits are only useful while live; they must not become saved usage metrics.
    private var liveLimits: [String: Int64] = [:]
    public private(set) var evictedSessions = 0
    private enum CodingKeys: String, CodingKey {
        case version, key, records, receipts, evictedSessions
    }

    public init() {
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try values.decode(Int.self, forKey: .version)
        guard savedVersion == 1 || savedVersion == 2 else { throw SessionAttentionError.invalidStorage }
        key = try values.decode(Data.self, forKey: .key)
        records = try values.decode([String: Record].self, forKey: .records)
        receipts = try values.decode([String: Date].self, forKey: .receipts)
        evictedSessions = try values.decode(Int.self, forKey: .evictedSessions)
        try validate()
    }

    public var notices: [SessionNotice] {
        records.values.flatMap { $0.notices.values }.sorted {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority < $1.kind.priority }
            if ($0.viewedAt == nil) != ($1.viewedAt == nil) { return $0.viewedAt == nil }
            if $0.began != $1.began { return $0.began > $1.began }
            return $0.id < $1.id
        }
    }

    public var sessionCount: Int { records.count }
    public var receiptCount: Int { receipts.count }

    private func pseudonym(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func sessionID(source: Client, hash: String) -> String {
        pseudonym("session:\(source.rawValue):\(hash)")
    }

    public func notice(for event: ActivityEvent) -> SessionNotice? {
        guard let kind = SessionNoticeKind(eventKind: event.kind) else { return nil }
        let notice = records[sessionID(source: event.source, hash: event.session)]?.notices[kind.rawValue]
        return notice?.observedAt == event.timestamp ? notice : nil
    }

    public func validate() throws {
        func hash(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        guard version == 2, key.count == 32, records.count <= Self.sessionLimit,
              receipts.count <= Self.receiptLimit, evictedSessions >= 0 else {
            throw SessionAttentionError.invalidStorage
        }
        for (id, record) in records {
            guard hash(id), record.notices.count <= SessionNoticeKind.allCases.count,
                  record.lifecycle?.isActivitySnapshot != true,
                  record.lifecycle?.isMetric != true,
                  record.lifecycle?.isAttention != true,
                  [record.updatedAt, record.lifecycleAt, record.contextAt, record.compactionAt, record.workBoundary]
                    .compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
                throw SessionAttentionError.invalidStorage
            }
            for (kind, notice) in record.notices {
                guard kind == notice.kind.rawValue, notice.sessionID == id,
                      notice.source == record.source, hash(notice.id),
                      !notice.kind.isRequest || notice.source == .cli,
                      notice.observedAt >= notice.began,
                      [notice.began, notice.observedAt, notice.viewedAt].compactMap({ $0 })
                        .allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw SessionAttentionError.invalidStorage }
            }
        }
        guard receipts.keys.allSatisfy(hash), receipts.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw SessionAttentionError.invalidStorage
        }
    }

    @discardableResult
    public mutating func observe(_ event: ActivityEvent, now: Date) throws -> Bool {
        try event.validate(now: now)
        guard event.kind != .usage else { return false }
        let session = sessionID(source: event.source, hash: event.session)
        if event.kind.isActivitySnapshot {
            guard event.kind == .active, var record = records[session],
                  var stop = record.notices[SessionNoticeKind.stopped.rawValue],
                  stop.disposition == .pending, event.timestamp > stop.observedAt else { return false }
            stop.disposition = .superseded
            record.notices[SessionNoticeKind.stopped.rawValue] = stop
            records[session] = record
            return true
        }
        let phase = event.compaction.map { $0.success == nil ? "start" : "complete" } ?? ""
        let receipt = pseudonym("event:\(event.id):\(phase)")
        guard receipts[receipt] == nil else { return false }
        var record = records[session] ?? Record(source: event.source, updatedAt: event.timestamp)

        func close(_ kind: SessionNoticeKind, as disposition: SessionNoticeDisposition) {
            guard var notice = record.notices[kind.rawValue],
                  notice.observedAt <= event.timestamp else { return }
            // Resolved/superseded closes even a dismissed episode so a new one can surface.
            notice.disposition = disposition
            record.notices[kind.rawValue] = notice
        }
        func open(_ kind: SessionNoticeKind, coalesce: Bool) {
            if let previous = record.notices[kind.rawValue], previous.observedAt > event.timestamp { return }
            if coalesce, var notice = record.notices[kind.rawValue],
               notice.disposition == .pending || notice.disposition == .dismissed {
                notice.observedAt = event.timestamp
                record.notices[kind.rawValue] = notice
            } else {
                record.notices[kind.rawValue] = SessionNotice(
                    id: pseudonym("notice:\(event.id):\(kind.rawValue)"), sessionID: session,
                    source: event.source, kind: kind, began: event.timestamp, observedAt: event.timestamp)
            }
        }

        if event.kind.isAttention {
            guard let kind = SessionNoticeKind(eventKind: event.kind),
                  record.workBoundary.map({ event.timestamp > $0 }) ?? true,
                  record.lifecycle.map({ ![EventKind.ended, .cancelled, .failed].contains($0) }) ?? true,
                  record.notices[kind.rawValue].map({ event.timestamp > $0.observedAt }) ?? true else { return false }
            open(kind, coalesce: kind == .error)
        } else if event.kind.isMetric {
            guard record.workBoundary.map({ event.timestamp > $0 }) ?? true,
                  record.lifecycle.map({ ![EventKind.ended, .cancelled, .failed].contains($0) }) ?? true else { return false }
            if event.kind == .contextInvalidated {
                guard record.contextAt.map({ event.timestamp > $0 }) ?? true else { return false }
                record.contextAt = event.timestamp
                liveLimits.removeValue(forKey: session)
                close(.context, as: .superseded)
            } else if let context = event.context {
                guard record.contextAt.map({ event.timestamp > $0 }) ?? true else { return false }
                record.contextAt = event.timestamp
                liveLimits[session] = context.tokenLimit
                if context.fraction >= 0.8 { open(.context, coalesce: true) }
                else { close(.context, as: .resolved) }
            } else if let compaction = event.compaction {
                guard record.compactionAt.map({
                    event.timestamp > $0 || (event.timestamp == $0 && !record.compactionCompleted && compaction.success != nil)
                }) ?? true else { return false }
                record.compactionAt = event.timestamp
                record.compactionCompleted = compaction.success != nil
                if compaction.success == false { open(.compaction, coalesce: true) }
                if compaction.success == true {
                    close(.compaction, as: .resolved)
                    if let after = compaction.after, let limit = liveLimits[session],
                       record.contextAt.map({ $0 < event.timestamp && event.timestamp.timeIntervalSince($0) <= 300 }) == true,
                       Double(after) / Double(limit) < 0.8 {
                        close(.context, as: .resolved)
                        record.contextAt = event.timestamp
                    }
                }
            }
        } else {
            if let date = record.lifecycleAt {
                guard event.timestamp > date ||
                        (event.timestamp == date && event.kind.order > (record.lifecycle?.order ?? -1)) else { return false }
            }
            record.lifecycleAt = event.timestamp
            record.lifecycle = event.kind
            switch event.kind {
            case .working:
                record.workBoundary = event.timestamp
                close(.stopped, as: .superseded)
                close(.error, as: .superseded)
                close(.compaction, as: .superseded)
                close(.input, as: .superseded)
                close(.approval, as: .superseded)
            case .stopped:
                open(.stopped, coalesce: false)
            case .failed, .ended, .cancelled:
                record.workBoundary = event.timestamp
                close(.context, as: .superseded)
                close(.compaction, as: .superseded)
                close(.stopped, as: .superseded)
                close(.input, as: .superseded)
                close(.approval, as: .superseded)
                if event.kind == .failed { open(.error, coalesce: true) }
            default: break
            }
        }
        record.updatedAt = max(record.updatedAt, event.timestamp)
        records[session] = record
        receipts[receipt] = now
        prune(now: now)
        return true
    }

    @discardableResult
    public mutating func markViewed(_ ids: Set<String>, now: Date) -> Bool {
        change(ids) { notice in
            if notice.viewedAt == nil { notice.viewedAt = now }
        }
    }

    @discardableResult
    public mutating func dismiss(_ ids: Set<String>) -> Bool {
        change(ids) { notice in notice.disposition = .dismissed }
    }

    private mutating func change(_ ids: Set<String>, update: (inout SessionNotice) -> Void) -> Bool {
        var changed = false
        for session in Array(records.keys) {
            guard var record = records[session] else { continue }
            for kind in Array(record.notices.keys) {
                guard var notice = record.notices[kind], ids.contains(notice.id),
                      notice.disposition == .pending else { continue }
                let before = notice
                update(&notice)
                record.notices[kind] = notice
                changed = changed || before != notice
            }
            records[session] = record
        }
        return changed
    }

    public mutating func remove(_ source: Client) {
        records = records.filter { $0.value.source != source }
        liveLimits = liveLimits.filter { records[$0.key] != nil }
    }

    public mutating func prune(now: Date) {
        receipts = receipts.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }
        records = records.filter {
            $0.value.notices.values.contains(where: \.needsHighlight) ||
                now.timeIntervalSince($0.value.updatedAt) < 7 * 86_400
        }
        while receipts.count > Self.receiptLimit {
            let oldest = receipts.min { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            if let oldest { receipts.removeValue(forKey: oldest.key) }
        }
        while records.count > Self.sessionLimit {
            let oldest = records.min {
                let a = $0.value.notices.values.contains(where: \.needsHighlight)
                let b = $1.value.notices.values.contains(where: \.needsHighlight)
                if a != b { return !a }
                return $0.value.updatedAt == $1.value.updatedAt
                    ? $0.key < $1.key : $0.value.updatedAt < $1.value.updatedAt
            }
            if let oldest {
                records.removeValue(forKey: oldest.key)
                evictedSessions += 1
            }
        }
        liveLimits = liveLimits.filter { records[$0.key] != nil }
    }
}
