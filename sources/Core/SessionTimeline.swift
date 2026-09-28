import Foundation

public enum TimelineError: String, Error, LocalizedError {
    case storage = "Session timelines could not be saved or read. Recording is paused; saved data was not reset."
    case schema = "This timeline archive needs a newer Tokenotch version. It was left unchanged."
    case invalid = "Unsupported timeline data. The archive was left unchanged."
    case queueFull = "Timeline recording could not keep up. Recording is paused; observations may be missing."
    public var errorDescription: String? { rawValue }
}

public enum TimelineRetention: Int, CaseIterable, Identifiable, Sendable {
    case one = 1, seven = 7, thirty = 30
    public var id: Int { rawValue }
}

public struct TimelineSession: Identifiable, Sendable {
    public let id: String
    public let source: Client
    public let first: Date
    public let last: Date
    public let count: Int
    public let truncated: Bool
    public var label: String { "\(source.title) session \(id.prefix(8))" }
}

public struct TimelineEvent: Codable, Identifiable, Sendable {
    public let id: String
    public let session: String
    public let source: Client
    public let timestamp: Date
    public let kind: EventKind
    public let model: String?
    public let input: Int64?
    public let output: Int64?
    public let cacheInput: Int64?
    public let firstTokenMs: Double?
    public let durationMs: Double?
    public let contextTokens: Int64?
    public let contextLimit: Int64?
    public let compactionSuccess: Bool?
    public let before: Int64?
    public let after: Int64?
    public var cacheInputReported: Bool? = nil
    public var cacheWrite: Int64? = nil
    public var cacheWriteReported: Bool? = nil
    public var accountingVersion: Int? = TokenUsage.accountingVersion
    public var metricSource: UsageSource? = nil

    public var cacheCoverage: CacheInputCoverage? {
        guard kind == .usage else { return nil }
        return CacheInputCoverage(tokens: cacheInput ?? 0, calls: 1,
            reportedCalls: cacheInputReported == true ? 1 : 0,
            unreportedCalls: cacheInputReported == false ? 1 : 0)
    }
    public var breakdown: TokenBreakdown? {
        guard let read = cacheCoverage else { return nil }
        return TokenBreakdown(read: read,
            write: CacheInputCoverage(tokens: cacheWrite ?? 0, calls: 1,
                reportedCalls: cacheWriteReported == true ? 1 : 0,
                unreportedCalls: cacheWriteReported == false ? 1 : 0, kind: .write),
            unverifiedCalls: accountingVersion == nil ? 1 : 0)
    }

    public func validate() throws {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
              !kind.isActivitySnapshot, !kind.isAttention, kind != .contextInvalidated,
              source == .cli || [.started, .working, .stopped].contains(kind) ||
                (kind == .usage && metricSource != nil) else { throw TimelineError.invalid }
        let tokens: TokenUsage?
        let context: ContextUsage?
        let compaction: CompactionUsage?
        if kind == .usage {
            guard let input, let output, contextTokens == nil, contextLimit == nil,
                  cacheInputReported != true || cacheInput != nil,
                  cacheWriteReported != true || cacheWrite != nil,
                  accountingVersion == nil || accountingVersion == TokenUsage.accountingVersion,
                  compactionSuccess == nil, before == nil, after == nil else { throw TimelineError.invalid }
            tokens = TokenUsage(callID: id, input: input, output: output, cacheInput: cacheInput ?? 0,
                                cacheInputReported: cacheInputReported, model: model,
                                durationMs: durationMs, timeToFirstTokenMs: firstTokenMs,
                                cacheWrite: cacheWrite ?? 0, cacheWriteReported: cacheWriteReported)
            context = nil
            compaction = nil
        } else {
            guard model == nil, input == nil, output == nil, cacheInput == nil,
                  cacheInputReported == nil, cacheWrite == nil, cacheWriteReported == nil,
                  firstTokenMs == nil, durationMs == nil else {
                throw TimelineError.invalid
            }
            tokens = nil
            if kind == .context {
                guard let contextTokens, let contextLimit, compactionSuccess == nil,
                      before == nil, after == nil else { throw TimelineError.invalid }
                context = ContextUsage(currentTokens: contextTokens, tokenLimit: contextLimit)
            } else {
                guard contextTokens == nil, contextLimit == nil else { throw TimelineError.invalid }
                context = nil
            }
            if kind == .compaction {
                compaction = CompactionUsage(success: compactionSuccess, before: before, after: after)
            } else {
                guard compactionSuccess == nil, before == nil, after == nil else { throw TimelineError.invalid }
                compaction = nil
            }
        }
        try ActivityEvent(source: source, session: session, kind: kind, timestamp: timestamp,
            tokens: tokens, context: context, compaction: compaction,
            metricID: kind == .compaction ? id : nil, metricSource: metricSource).validate(now: timestamp)
    }

    public var title: String {
        switch kind {
        case .started: return "Session observed"
        case .working: return "Working (last reported)"
        case .active: return "Working (live)"
        case .idle: return "Idle (live)"
        case .stopped: return "Execution stopped (not proof of success)"
        case .ended: return "Session ended"
        case .cancelled: return "Session cancelled"
        case .inputRequested: return "Input requested (last reported)"
        case .approvalRequested: return "Approval requested (last reported)"
        case .unrecoverableError: return "Unrecoverable error reported"
        case .failed: return "Session ended with an error"
        case .usage: return "Observed model call"
        case .context: return "Context reading"
        case .contextInvalidated: return "Context awaiting a new reading"
        case .compaction:
            return compactionSuccess.map { $0 ? "Compaction completed" : "Compaction failed" } ?? "Compaction started"
        }
    }

    public func annotation(previous: TimelineEvent?, timestampIsAmbiguous: Bool) -> String? {
        guard !timestampIsAmbiguous, let previous, previous.kind == kind,
              previous.timestamp < timestamp else { return nil }
        if kind == .usage, let model, let old = previous.model, model != old {
            return "Model differs from previous observed call (\(old)); not an explicit switch event."
        }
        if kind == .context, let count = contextTokens, let old = previous.contextTokens {
            return "Change from previous observed context: \(count - old) tokens. A decrease does not prove compaction."
        }
        return nil
    }
}

extension TimelineEvent {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        session = try values.decode(String.self, forKey: .session)
        source = try values.decode(Client.self, forKey: .source)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        kind = try values.decode(EventKind.self, forKey: .kind)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        input = try values.decodeIfPresent(Int64.self, forKey: .input)
        output = try values.decodeIfPresent(Int64.self, forKey: .output)
        cacheInput = try values.contains(.cacheInput) ? values.decode(Int64.self, forKey: .cacheInput) : nil
        cacheInputReported = try values.contains(.cacheInputReported)
            ? values.decode(Bool.self, forKey: .cacheInputReported) : nil
        cacheWrite = try values.contains(.cacheWrite) ? values.decode(Int64.self, forKey: .cacheWrite) : nil
        cacheWriteReported = try values.contains(.cacheWriteReported)
            ? values.decode(Bool.self, forKey: .cacheWriteReported) : nil
        accountingVersion = try values.contains(.accountingVersion)
            ? values.decode(Int.self, forKey: .accountingVersion) : nil
        metricSource = try values.decodeIfPresent(UsageSource.self, forKey: .metricSource)
        firstTokenMs = try values.decodeIfPresent(Double.self, forKey: .firstTokenMs)
        durationMs = try values.decodeIfPresent(Double.self, forKey: .durationMs)
        contextTokens = try values.decodeIfPresent(Int64.self, forKey: .contextTokens)
        contextLimit = try values.decodeIfPresent(Int64.self, forKey: .contextLimit)
        compactionSuccess = try values.decodeIfPresent(Bool.self, forKey: .compactionSuccess)
        before = try values.decodeIfPresent(Int64.self, forKey: .before)
        after = try values.decodeIfPresent(Int64.self, forKey: .after)
    }
}

public struct TimelinePage: Sendable {
    public let events: [TimelineEvent]
    public let hasMore: Bool
}

public struct TimelineStatus: Sendable {
    public let sessionCount: Int
    public let eventCount: Int
    public let pruned: Bool
    public let interrupted: Bool
}
