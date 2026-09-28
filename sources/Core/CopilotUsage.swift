import Foundation

public enum CopilotConnectionError: String, Error, LocalizedError {
    case missingCLI = "Select an installed GitHub Copilot CLI executable."
    case signIn = "Sign in to GitHub to connect this Copilot account."
    case loginFailed = "GitHub sign-in did not finish. Retry or cancel and check the browser."
    case timeout = "Copilot did not respond before the deadline."
    case incompatible = "Tokenotch and this Copilot CLI use incompatible account APIs. Check for updates to Tokenotch and the CLI."
    case invalidResponse = "Copilot returned an unsupported usage response."
    case rateLimited = "Copilot rate-limited the request. Refresh is paused for five minutes."
    case forbidden = "Copilot access is restricted by account or enterprise policy."
    case failed = "Could not read Copilot usage. Check the connection and try again."
    public var errorDescription: String? { rawValue }
}

public struct CopilotIdentity: Decodable, Equatable {
    public let isAuthenticated: Bool
    public let login: String?
    public let host: String?
    public let authType: String?
    public let copilotPlan: String?
}

public struct CopilotQuota: Decodable, Identifiable {
    public var id: String = ""
    public let isUnlimitedEntitlement: Bool
    public let entitlementRequests: Decimal
    public let usedRequests: Decimal
    public let remainingPercentage: Double
    public let overage: Decimal?
    public let resetDate: String?
    private enum CodingKeys: String, CodingKey {
        case isUnlimitedEntitlement, entitlementRequests, usedRequests, remainingPercentage, overage, resetDate
    }
    public var title: String {
        switch id {
        case "premium_interactions": return "Premium requests"
        case "chat": return "Chat requests"
        case "completions": return "Completions"
        default: return "Runtime quota (\(id))"
        }
    }
    public var reportedReset: Date? {
        guard let resetDate else { return nil }
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: resetDate) { return value }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetDate)
    }
}

public struct CopilotAccountSnapshot {
    public let identity: CopilotIdentity
    public let quotas: [CopilotQuota]
    public let observedAt: Date
    public let runtimeVersion: String
    public var primaryQuota: CopilotQuota? {
        quotas.first { $0.id == "premium_interactions" }
            ?? quotas.first { !$0.isUnlimitedEntitlement } ?? quotas.first
    }

    public static func parse(identity: Data, quota: Data, version: String, now: Date = Date()) throws -> Self {
        struct Quotas: Decodable { let quotaSnapshots: [String: CopilotQuota] }
        let user = try JSONDecoder().decode(CopilotIdentity.self, from: identity)
        guard user.isAuthenticated, let login = user.login, !login.isEmpty, login.count <= 100 else {
            throw CopilotConnectionError.signIn
        }
        let values = try JSONDecoder().decode(Quotas.self, from: quota)
        guard values.quotaSnapshots.count <= 20 else { throw CopilotConnectionError.invalidResponse }
        let quotas = try values.quotaSnapshots.map { key, value -> CopilotQuota in
            guard key.count <= 64, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  !value.usedRequests.isNaN, value.usedRequests >= 0,
                  !value.entitlementRequests.isNaN, value.entitlementRequests >= -1,
                  value.isUnlimitedEntitlement || value.entitlementRequests >= 0,
                  value.remainingPercentage.isFinite, (0...100).contains(value.remainingPercentage),
                  value.overage.map({ !$0.isNaN && $0 >= 0 }) ?? true else {
                throw CopilotConnectionError.invalidResponse
            }
            var result = value
            result.id = key
            return result
        }.sorted {
            if $0.id == "premium_interactions" { return true }
            if $1.id == "premium_interactions" { return false }
            return $0.id < $1.id
        }
        return Self(identity: user, quotas: quotas, observedAt: now, runtimeVersion: version)
    }
}

public struct RPCFrames {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        guard buffer.count <= 1_048_576 else { throw CopilotConnectionError.invalidResponse }
        var result: [Data] = []
        let delimiter = Data("\r\n\r\n".utf8)
        while let boundary = buffer.range(of: delimiter) {
            guard boundary.lowerBound <= 1024,
                  let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
                throw CopilotConnectionError.invalidResponse
            }
            let lengths = header.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("content-length:") }
            guard lengths.count == 1, let field = lengths.first,
                  let length = Int(field.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)),
                  length > 0, length <= 262_144 else { throw CopilotConnectionError.invalidResponse }
            let end = boundary.upperBound + length
            guard buffer.count >= end else { break }
            result.append(buffer.subdata(in: boundary.upperBound..<end))
            buffer.removeSubrange(..<end)
        }
        if buffer.range(of: delimiter) == nil && buffer.count > 1024 { throw CopilotConnectionError.invalidResponse }
        return result
    }
    public static func encode(id: Int, method: String) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": [:]])
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public static let accountingVersion = 1
    public let callID: String
    public let input: Int64
    public let output: Int64
    public let cacheInput: Int64
    public let cacheInputReported: Bool?
    public let cacheWrite: Int64
    public let cacheWriteReported: Bool?
    public let accountingVersion: Int?
    public let model: String?
    public let durationMs: Double?
    public let timeToFirstTokenMs: Double?
    public init(callID: String, input: Int64, output: Int64, cacheInput: Int64 = 0,
                cacheInputReported: Bool? = nil, model: String? = nil,
                durationMs: Double? = nil, timeToFirstTokenMs: Double? = nil,
                cacheWrite: Int64 = 0, cacheWriteReported: Bool? = nil) {
        self.callID = callID; self.input = input; self.output = output; self.cacheInput = cacheInput; self.model = model
        self.cacheInputReported = cacheInputReported
        self.cacheWrite = cacheWrite
        self.cacheWriteReported = cacheWriteReported
        accountingVersion = Self.accountingVersion
        self.durationMs = durationMs; self.timeToFirstTokenMs = timeToFirstTokenMs
    }
    private enum CodingKeys: String, CodingKey {
        case callID, input, output, cacheInput, cacheInputReported, model, durationMs, timeToFirstTokenMs
        case cacheWrite, cacheWriteReported, accountingVersion
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(String.self, forKey: .callID)
        input = try values.decode(Int64.self, forKey: .input)
        output = try values.decode(Int64.self, forKey: .output)
        cacheInputReported = try values.contains(.cacheInputReported)
            ? values.decode(Bool.self, forKey: .cacheInputReported) : nil
        cacheInput = try values.contains(.cacheInput) || cacheInputReported == true
            ? values.decode(Int64.self, forKey: .cacheInput) : 0
        cacheWriteReported = try values.contains(.cacheWriteReported)
            ? values.decode(Bool.self, forKey: .cacheWriteReported) : nil
        cacheWrite = try values.contains(.cacheWrite) || cacheWriteReported == true
            ? values.decode(Int64.self, forKey: .cacheWrite) : 0
        accountingVersion = try values.contains(.accountingVersion)
            ? values.decode(Int.self, forKey: .accountingVersion) : nil
        model = try values.decodeIfPresent(String.self, forKey: .model)
        durationMs = try values.decodeIfPresent(Double.self, forKey: .durationMs)
        timeToFirstTokenMs = try values.decodeIfPresent(Double.self, forKey: .timeToFirstTokenMs)
    }
    public static func validLatency(_ value: Double) -> Bool { value.isFinite && (0...86_400_000).contains(value) }
    public func validate() throws {
        guard accountingVersion == Self.accountingVersion else { throw TokenotchError.metricUpgrade }
        guard callID.count == 64, callID.allSatisfy({ "0123456789abcdef".contains($0) }),
              (0...1_000_000_000).contains(input), (0...1_000_000_000).contains(output),
              (0...1_000_000_000).contains(cacheInput),
              (0...1_000_000_000).contains(cacheWrite),
              cacheInputReported != false || cacheInput == 0,
              cacheWriteReported != false || cacheWrite == 0 else { throw TokenotchError.invalidEvent }
        for value in [durationMs, timeToFirstTokenMs].compactMap({ $0 }) {
            guard Self.validLatency(value) else { throw TokenotchError.invalidEvent }
        }
        if let model {
            guard !model.isEmpty, model.utf8.count <= 128,
                  model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._:/".contains($0)) }) else {
                throw TokenotchError.invalidEvent
            }

        }
    }

    public var cacheCoverage: CacheInputCoverage {
        CacheInputCoverage(tokens: cacheInput, calls: 1,
            reportedCalls: cacheInputReported == true ? 1 : 0,
            unreportedCalls: cacheInputReported == false ? 1 : 0)
    }
    public var breakdown: TokenBreakdown {
        TokenBreakdown(read: cacheCoverage,
            write: CacheInputCoverage(tokens: cacheWrite, calls: 1,
                reportedCalls: cacheWriteReported == true ? 1 : 0,
                unreportedCalls: cacheWriteReported == false ? 1 : 0, kind: .write),
            unverifiedCalls: accountingVersion == nil ? 1 : 0)
    }
}

public struct CacheInputCoverage: Equatable, Sendable {
    public enum Kind: Sendable { case read, write }
    public enum State: Equatable, Sendable {
        case noSamples, reported, notReported, unknown, partial
    }
    public let tokens: Int64
    public let calls: Int64
    public let reportedCalls: Int64
    public let unreportedCalls: Int64
    public let kind: Kind

    public init(tokens: Int64, calls: Int64, reportedCalls: Int64, unreportedCalls: Int64, kind: Kind = .read) {
        self.tokens = tokens; self.calls = calls
        self.reportedCalls = reportedCalls; self.unreportedCalls = unreportedCalls
        self.kind = kind
    }

    public var isValid: Bool {
        tokens >= 0 && calls >= 0 && reportedCalls >= 0 && unreportedCalls >= 0
            && reportedCalls <= calls && unreportedCalls <= calls - reportedCalls
            && (calls > 0 || tokens == 0) && (unreportedCalls != calls || tokens == 0)
    }

    public var unknownCalls: Int64 { calls - reportedCalls - unreportedCalls }
    public var state: State {
        if calls == 0 { return .noSamples }
        if reportedCalls == calls { return .reported }
        if unreportedCalls == calls { return .notReported }
        if reportedCalls > 0 || tokens > 0 { return .partial }
        return .unknown
    }
    public var hasValue: Bool { state == .reported || state == .partial }
    public var isIncomplete: Bool { calls > 0 && reportedCalls < calls }
}

public struct TokenBreakdown: Equatable, Sendable {
    public let read: CacheInputCoverage
    public let write: CacheInputCoverage
    public let unverifiedCalls: Int64
    public init(read: CacheInputCoverage, write: CacheInputCoverage, unverifiedCalls: Int64 = 0) {
        self.read = read; self.write = write; self.unverifiedCalls = unverifiedCalls
    }
    public var isIncomplete: Bool { read.isIncomplete || write.isIncomplete }
    public var inputLabel: String {
        isIncomplete ? "Input (breakdown incomplete)" : "Input"
    }
}

public struct CompactionUsage: Codable, Equatable, Sendable {
    public let success: Bool?
    public let before: Int64?
    public let after: Int64?
    public init(success: Bool?, before: Int64? = nil, after: Int64? = nil) {
        self.success = success; self.before = before; self.after = after
    }
    public func validate() throws {
        guard success != nil || (before == nil && after == nil) else { throw TokenotchError.invalidEvent }
        for value in [before, after].compactMap({ $0 }) {
            guard (0...1_000_000_000).contains(value) else { throw TokenotchError.invalidEvent }
        }
    }
}

public struct SessionInsight: Identifiable {
    public let id: String
    public var context: ObservedContext?
    public var latency: TokenUsage?
    public var latencyAt: Date?
    public var compaction: CompactionUsage?
    public var compactionAt: Date?
    public var observedAt: Date
    public func compactionLabel(now: Date) -> String? {
        guard let compaction, let date = compactionAt else { return nil }
        guard now.timeIntervalSince(date) <= 300 else { return "Compaction observation stale" }
        if let success = compaction.success { return success ? "Compaction completed" : "Compaction failed" }
        return "Compacting"
    }
}

public struct SessionInsights {
    private var values: [String: SessionInsight] = [:]
    private var contexts = ContextReadings()
    public init() {}
    public var sessions: [SessionInsight] { values.values.sorted { $0.observedAt > $1.observedAt } }
    public mutating func observe(_ event: ActivityEvent, now: Date) {
        values = values.filter { now.timeIntervalSince($0.value.observedAt) < 86_400 }
        var value = values[event.session] ?? SessionInsight(id: event.session, observedAt: event.timestamp)
        if event.kind == .context || event.kind == .contextInvalidated {
            contexts.observe(event, now: now)
            value.context = contexts.values[event.session]?.context
        }
        if let tokens = event.tokens, event.timestamp > (value.latencyAt ?? .distantPast) {
            value.latency = tokens; value.latencyAt = event.timestamp
        }
        if let compaction = event.compaction,
           event.timestamp > (value.compactionAt ?? .distantPast)
            || (event.timestamp == value.compactionAt && value.compaction?.success == nil && compaction.success != nil) {
            value.compaction = compaction; value.compactionAt = event.timestamp
        }
        value.observedAt = max(value.observedAt, event.timestamp)
        values[event.session] = value
        if values.count > 100, let first = values.min(by: { $0.value.observedAt < $1.value.observedAt }) {
            values.removeValue(forKey: first.key)
        }
    }
}

public struct ContextUsage: Codable, Equatable, Sendable {
    public let currentTokens: Int64
    public let tokenLimit: Int64
    public init(currentTokens: Int64, tokenLimit: Int64) {
        self.currentTokens = currentTokens; self.tokenLimit = tokenLimit
    }
    public func validate() throws {
        guard (0...1_000_000_000).contains(currentTokens),
              (1...1_000_000_000).contains(tokenLimit) else { throw TokenotchError.invalidEvent }
    }
    public var fraction: Double { Double(currentTokens) / Double(tokenLimit) }
}

public struct ObservedTokens {
    public let input: Int64
    public let output: Int64
    public let cacheInput: Int64
    public let cacheReportedCalls: Int64
    public let cacheUnreportedCalls: Int64
    public let calls: Int
    public let since: Date
    public let lastObserved: Date
    public var cacheWrite: Int64 = 0
    public var cacheWriteReportedCalls: Int64 = 0
    public var cacheWriteUnreportedCalls: Int64 = 0
    public var total: Int64 { input + output + cacheInput + cacheWrite }
    public var cacheCoverage: CacheInputCoverage {
        CacheInputCoverage(tokens: cacheInput, calls: Int64(calls),
            reportedCalls: cacheReportedCalls, unreportedCalls: cacheUnreportedCalls)
    }
    public var breakdown: TokenBreakdown {
        TokenBreakdown(read: cacheCoverage,
            write: CacheInputCoverage(tokens: cacheWrite, calls: Int64(calls),
                reportedCalls: cacheWriteReportedCalls, unreportedCalls: cacheWriteUnreportedCalls, kind: .write))
    }
}

public struct ObservedModelTokens: Identifiable {
    public let model: String?
    public let tokens: ObservedTokens
    public var id: String { model ?? "" }
    public var title: String { model ?? "Model unavailable" }
}

public struct ObservedContext {
    public let usage: ContextUsage
    public let observedAt: Date
    public init(usage: ContextUsage, observedAt: Date) {
        self.usage = usage; self.observedAt = observedAt
    }
    public func isStale(now: Date) -> Bool { now.timeIntervalSince(observedAt) > 300 }
}

private struct ContextReadings {
    struct Reading {
        let context: ObservedContext?
        let date: Date
    }
    private(set) var values: [String: Reading] = [:]

    mutating func observe(_ event: ActivityEvent, now: Date) {
        expire(now: now)
        guard event.timestamp > (values[event.session]?.date ?? .distantPast) else { return }
        // Keep an invalidation timestamp so delayed readings cannot restore the old window.
        values[event.session] = Reading(
            context: event.context.map { ObservedContext(usage: $0, observedAt: event.timestamp) },
            date: event.timestamp)
        if values.count > 100, let first = values.min(by: { $0.value.date < $1.value.date }) {
            values.removeValue(forKey: first.key)
        }
    }

    mutating func expire(now: Date) {
        values = values.filter { now.timeIntervalSince($0.value.date) < 86_400 }
    }
}

public struct ObservedSessionMetrics: Identifiable {
    public let id: String
    public let tokens: ObservedTokens?
    public let context: ObservedContext?
    public let lastObserved: Date
    public var source: UsageSource = .cli
    public var sessionReported = true
}

public struct TokenLedger {
    private struct Sample {
        let session: String
        let usage: TokenUsage
        let date: Date
        let source: UsageSource
        let sessionReported: Bool
    }
    private var samples: [String: Sample] = [:]
    private var hourlyCache: (asOf: Date, until: Date, timeline: UsageTimeline)?
    private var contexts = ContextReadings()
    public private(set) var lastDiscardedAt: Date?
    public init() {}
    public mutating func observe(_ event: ActivityEvent, now: Date, allowingDelayed: Bool = false) throws {
        if allowingDelayed {
            try event.validatePayload()
            guard event.metricSource != nil, event.timestamp <= now.addingTimeInterval(30),
                  event.timestamp > now.addingTimeInterval(-86_400) else { throw TokenotchError.invalidEvent }
        } else { try event.validate(now: now) }
        guard event.kind == .usage || event.kind == .context || event.kind == .contextInvalidated else { throw TokenotchError.invalidEvent }
        expire(now: now)
        if event.kind == .context || event.kind == .contextInvalidated {
            contexts.observe(event, now: now)
            return
        }
        guard let tokens = event.tokens else { throw TokenotchError.invalidEvent }
        guard samples[tokens.callID] == nil else { return }
        samples[tokens.callID] = Sample(session: event.session, usage: tokens, date: event.timestamp,
                                       source: event.usageSource, sessionReported: event.metricSessionReported != false)
        hourlyCache = nil
        if samples.count > 4096, let first = samples.min(by: { $0.value.date < $1.value.date }) {
            lastDiscardedAt = max(lastDiscardedAt ?? .distantPast, first.value.date)
            samples.removeValue(forKey: first.key)
        }
    }
    public mutating func expire(now: Date) {
        let previousCount = samples.count
        samples = samples.filter { now.timeIntervalSince($0.value.date) < 86_400 }
        if samples.count != previousCount { hourlyCache = nil }
        contexts.expire(now: now)
        if let discarded = lastDiscardedAt, now.timeIntervalSince(discarded) >= 86_400 { lastDiscardedAt = nil }
    }
    public var totals: ObservedTokens? { Self.total(Array(samples.values)) }

    public func filtered(_ source: UsageSource?) -> Self {
        guard let source else { return self }
        var result = self
        result.samples = samples.filter { $0.value.source == source }
        if source != .cli { result.contexts = ContextReadings() }
        result.hourlyCache = nil
        return result
    }

    public mutating func remove(_ source: UsageSource) {
        samples = samples.filter { $0.value.source != source }
        if source == .cli { contexts = ContextReadings() }
        hourlyCache = nil
    }

    public func today(now: Date, calendar: Calendar = .current) -> ObservedTokens? {
        Self.total(todaySamples(now: now, calendar: calendar))
    }

    public func todayByModel(now: Date, calendar: Calendar = .current) -> [ObservedModelTokens] {
        Self.models(todaySamples(now: now, calendar: calendar))
    }

    public mutating func hourlyTimeline(now: Date, calendar: Calendar = .current) -> UsageTimeline {
        let clock = HistoryCalendar(zone: calendar.timeZone)
        if let cache = hourlyCache, cache.timeline.zone == calendar.timeZone.identifier,
           now >= cache.asOf, now < cache.until { return cache.timeline }
        let intervals = clock.hours(on: now)
        var buckets = intervals.map { UsageBucket(interval: $0) }
        var nextChange = clock.interval(.today, selected: now, now: now).end
        for sample in samples.values {
            if sample.date > now { nextChange = min(nextChange, sample.date); continue }
            guard now.timeIntervalSince(sample.date) < 86_400,
                  let index = intervals.firstIndex(where: { $0.start <= sample.date && sample.date < $0.end }) else { continue }
            buckets[index].tokens += sample.usage.input + sample.usage.output + sample.usage.cacheInput + sample.usage.cacheWrite
            buckets[index].calls += 1
            nextChange = min(nextChange, sample.date.addingTimeInterval(86_400))
        }
        let timeline = UsageTimeline(granularity: .hour, buckets: buckets, zone: calendar.timeZone.identifier)
        hourlyCache = (now, nextChange, timeline)
        return timeline
    }

    private func todaySamples(now: Date, calendar: Calendar) -> [Sample] {
        let start = calendar.startOfDay(for: now)
        return samples.values.filter { $0.date >= start && $0.date <= now }
    }

    public var byModel: [ObservedModelTokens] {
        Self.models(Array(samples.values))
    }

    private static func models(_ samples: [Sample]) -> [ObservedModelTokens] {
        Dictionary(grouping: samples, by: { $0.usage.model ?? "" }).map { key, values in
            ObservedModelTokens(model: key.isEmpty ? nil : key, tokens: Self.total(values)!)
        }.sorted {
            let left = $0.tokens.total
            let right = $1.tokens.total
            return left == right ? $0.id < $1.id : left > right
        }
    }

    public var bySession: [ObservedSessionMetrics] {
        let groups = Dictionary(grouping: samples.values, by: \.session)
        return Set(groups.keys).union(contexts.values.keys).map { key in
            let tokens = groups[key].flatMap(Self.total)
            let reading = contexts.values[key]
            let context = reading?.context
            return ObservedSessionMetrics(id: key, tokens: tokens, context: context,
                lastObserved: max(tokens?.lastObserved ?? .distantPast, reading?.date ?? .distantPast),
                source: groups[key]?.first?.source ?? .cli,
                sessionReported: groups[key]?.first?.sessionReported ?? true)
        }.sorted { $0.lastObserved == $1.lastObserved ? $0.id < $1.id : $0.lastObserved > $1.lastObserved }
    }

    private static func total(_ values: [Sample]) -> ObservedTokens? {
        guard let first = values.map(\.date).min(), let last = values.map(\.date).max() else { return nil }
        return ObservedTokens(input: values.reduce(0) { $0 + $1.usage.input },
                              output: values.reduce(0) { $0 + $1.usage.output },
                              cacheInput: values.reduce(0) { $0 + $1.usage.cacheInput },
                              cacheReportedCalls: Int64(values.filter { $0.usage.cacheInputReported == true }.count),
                              cacheUnreportedCalls: Int64(values.filter { $0.usage.cacheInputReported == false }.count),
                              calls: values.count, since: first, lastObserved: last,
                              cacheWrite: values.reduce(0) { $0 + $1.usage.cacheWrite },
                              cacheWriteReportedCalls: Int64(values.filter { $0.usage.cacheWriteReported == true }.count),
                              cacheWriteUnreportedCalls: Int64(values.filter { $0.usage.cacheWriteReported == false }.count))
    }
}
