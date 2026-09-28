import Combine
import Foundation
import TokenotchCore
import os

struct HistoryNavigation {
    let id = UUID()
    let range: HistoryRange
    let anchor: Date
    let model: String?
}

// Mutable state is confined to queue; callbacks only publish on the main actor.
private final class HistoryWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.rottathiago.tokenotch.history", qos: .utility)
    let root: URL
    var store: UsageHistoryStore?
    var active = false
    var since = Date.distantFuture
    var lastHeartbeat = Date()
    var pending: [ActivityEvent] = []
    var flushScheduled = false
    var needsGap = false
    var sources: Set<UsageSource> = [.cli]
    var importID: UUID?
    var onCommit: ((Int) -> Void)?
    var onError: ((Error) -> Void)?
    init(root: URL) { self.root = root }

    func fail(_ error: Error) {
        active = false
        needsGap = true
        pending = []
        onError?(error)
    }
    func flush() throws {
        guard !pending.isEmpty else { return }
        guard let store else { throw HistoryError.storage }
        let batch = pending
        try store.record(batch)
        pending.removeAll(keepingCapacity: true)
        onCommit?(batch.count)
    }
    func accept(_ event: ActivityEvent) {
        guard active, sources.contains(event.usageSource), event.timestamp >= since else { onCommit?(1); return }
        pending.append(event)
        do {
            if pending.count >= 50 { try flush() }
            if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + 1) {
                    self.flushScheduled = false
                    do { try self.flush() } catch { self.fail(error) }
                }
            }
        } catch { fail(error) }
    }
    func stop(now: Date) throws {
        try flush()
        if active { try store?.heartbeat(from: lastHeartbeat, to: now, active: false, sources: sources) }
        active = false
        lastHeartbeat = now
    }
}

@MainActor
final class HistoryController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var status = "History is off"
    @Published private(set) var error: String?
    @Published private(set) var zone: String
    @Published private(set) var revision = 0 {
        didSet { refreshNotchSummary(now: Date()) }
    }
    @Published private(set) var recording = false
    @Published private(set) var notchSummary: NotchHistorySummary?
    @Published private(set) var comparison: HistoryInsightComparison?
    @Published var selectedEvidence: HistoryInsightEvidence?
    @Published var navigation: HistoryNavigation?
    @Published private(set) var notchRange: HistoryRange = .today
    @Published private(set) var todayUsage: HistorySnapshot?
    @Published private(set) var notchUsage: HistorySnapshot?
    @Published private(set) var notchTimeline: UsageTimeline?
    @Published private(set) var notchLoading = true
    @Published private(set) var notchAnchor: Date?
    @Published var selectedSource: UsageSource? {
        didSet {
            guard selectedSource != oldValue else { return }
            clearNotchSummary()
            refreshNotchSummary(now: Date())
        }
    }
    @Published private(set) var importPreview: TelemetryImportPreview?
    @Published private(set) var importNewCalls = 0
    @Published private(set) var importStatus: String?
    @Published private(set) var importBusy = false
    private var importTask: Task<Void, Never>?
    private var importGeneration = UUID()
    private var summaryTask: Task<Void, Never>?
    private var summaryKey: String?
    private var started = false
    private let defaults: UserDefaults
    nonisolated private let worker: HistoryWorker
    private var available = false
    private var availableSources: Set<UsageSource> = []
    private var generation = UUID()
    private var outstanding = 0
    private var failed = false
    private let log = Logger(subsystem: "io.github.rottathiago.tokenotch", category: "history")

    init(defaults: UserDefaults, root: URL) {
        self.defaults = defaults
        worker = HistoryWorker(root: root)
        enabled = defaults.bool(forKey: "usageHistoryEnabled")
        zone = defaults.string(forKey: "usageHistoryZone") ?? TimeZone.current.identifier
    }

    func start(available: Bool) {
        started = true
        self.available = available
        availableSources = available ? [.cli] : []
        configure()
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "usageHistoryEnabled")
        if value, defaults.string(forKey: "usageHistoryZone") == nil {
            zone = TimeZone.current.identifier
            defaults.set(zone, forKey: "usageHistoryZone")
        }
        configure()
    }
    func setAvailable(_ value: Bool) {
        setAvailableSources(value ? [.cli] : [])
    }
    func setAvailableSources(_ sources: Set<UsageSource>) {
        guard availableSources != sources else { return }
        availableSources = sources
        available = !sources.isEmpty
        configure()
    }
    func retry() { configure() }

    func markGap(sources: Set<UsageSource>) {
        guard recording else { return }
        worker.queue.async {
            do { try self.worker.store?.markGap(at: Date(), sources: sources) }
            catch { self.worker.fail(error) }
        }
    }

    func selectNotchRange(_ range: HistoryRange) {
        guard range == .today || range == .week, range != notchRange else { return }
        notchRange = range
        notchUsage = nil
        notchTimeline = nil
        notchLoading = true
        refreshNotchSummary(now: Date())
    }

    func navigate(range: HistoryRange, anchor: Date, model: String? = nil) {
        selectedEvidence = nil
        navigation = HistoryNavigation(range: range, anchor: anchor, model: model)
    }

    private func configure() {
        clearNotchSummary()
        let id = UUID()
        generation = id
        outstanding = 0
        recording = false
        failed = false
        error = nil
        let collect = enabled && available
        let wantsHistory = enabled
        let zoneName = zone
        let sources = availableSources
        status = enabled ? (available ? "Starting history recording" : "Paused: connect a usage source") : "History paused; saved data is retained"
        worker.queue.async { [self] in
            do {
                try self.worker.stop(now: Date())
                if self.worker.store == nil {
                    let exists = FileManager.default.fileExists(atPath: self.worker.root.appendingPathComponent("history/usage.sqlite").path)
                    if wantsHistory || exists {
                        guard let zone = TimeZone(identifier: zoneName) else { throw HistoryError.invalid }
                        self.worker.store = try UsageHistoryStore(root: self.worker.root, zone: zone)
                    }
                }
                if self.worker.needsGap {
                    try self.worker.store?.markGap(at: self.worker.lastHeartbeat, sources: self.worker.sources)
                    try self.worker.store?.markGap(at: Date(), sources: self.worker.sources)
                    self.worker.needsGap = false
                }
                self.worker.onCommit = { [weak self] count in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.outstanding = max(0, self.outstanding - count)
                        self.revision += 1
                    }
                }
                self.worker.onError = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.report(error)
                    }
                }
                self.worker.since = Date()
                self.worker.sources = sources
                self.worker.lastHeartbeat = self.worker.since
                self.worker.active = collect
                if collect {
                    try self.worker.store?.heartbeat(from: self.worker.since, to: self.worker.since, active: true, sources: sources)
                }
                let savedZone = self.worker.store?.clock.calendar.timeZone.identifier
                Task { @MainActor in
                    guard self.generation == id else { return }
                    if let savedZone { self.zone = savedZone }
                    self.recording = collect
                    if collect { self.status = "Recording observed usage locally" }
                    self.revision += 1
                }
            } catch {
                self.worker.active = false
                Task { @MainActor in
                    guard self.generation == id else { return }
                    self.report(error)
                }
            }
        }
    }

    func observe(_ event: ActivityEvent) {
        guard !event.kind.isAttention, enabled, availableSources.contains(event.usageSource), recording, !failed else { return }
        guard outstanding < 256 else {
            report(HistoryError.queueFull)
            worker.queue.async {
                do {
                    try self.worker.stop(now: Date())
                    try self.worker.store?.markGap(at: Date(), sources: self.worker.sources)
                } catch { self.worker.fail(error) }
            }
            return
        }
        outstanding += 1
        worker.queue.async { self.worker.accept(event) }
    }

    func tick(now: Date) {
        guard recording, !failed else {
            refreshNotchSummary(now: now)
            return
        }
        let id = generation
        worker.queue.async {
            guard self.worker.active else { return }
            do {
                try self.worker.flush()
                try self.worker.store?.heartbeat(from: self.worker.lastHeartbeat, to: now, active: true, sources: self.worker.sources)
                self.worker.lastHeartbeat = now
                Task { @MainActor in
                    guard self.generation == id else { return }
                    self.refreshNotchSummary(now: now)
                }
            } catch { self.worker.fail(error) }
        }
    }

    func read(_ interval: DateInterval, model: String?) async throws -> HistorySnapshot? {
        let source = selectedSource
        return try await withCheckedThrowingContinuation { continuation in
            worker.queue.async {
                do {
                    try self.worker.flush()
                    continuation.resume(returning: try self.worker.store?.query(interval, model: model, source: source))
                } catch {
                    self.worker.fail(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func previewImport(_ url: URL, source: UsageSource) {
        cancelImport()
        let id = UUID()
        importGeneration = id
        importPreview = nil
        importBusy = true
        importStatus = "Reading the selected telemetry export"
        importTask = Task {
            do {
                let reader = Task.detached(priority: .utility) {
                    try TelemetryImport.preview(url, source: source)
                }
                let preview = try await withTaskCancellationHandler(operation: { try await reader.value },
                    onCancel: { reader.cancel() })
                try Task.checkCancellation()
                let count: Int = try await withCheckedThrowingContinuation { continuation in
                    worker.queue.async {
                        do {
                            try self.worker.flush()
                            let count = try self.worker.store?.countNew(preview.events)
                                ?? Set(preview.events.compactMap { $0.tokens?.callID }).count
                            continuation.resume(returning: count)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                guard importGeneration == id else { return }
                importPreview = preview
                importNewCalls = count
                importStatus = "\(count) new calls; \(preview.rejected) unsupported records. Import requires confirmation."
            } catch {
                guard importGeneration == id else { return }
                importStatus = error is CancellationError ? "Preview cancelled" : importFailure(error)
            }
            if importGeneration == id { importBusy = false }
        }
    }

    func commitImport() {
        guard let preview = importPreview, !importBusy else { return }
        let id = UUID()
        importGeneration = id
        importBusy = true
        importStatus = "Importing usage history"
        if defaults.string(forKey: "usageHistoryZone") == nil {
            defaults.set(zone, forKey: "usageHistoryZone")
        }
        let zoneName = zone
        importTask = Task {
            var committed = 0
            do {
                let check = Task.detached(priority: .utility) { try TelemetryImport.validateUnchanged(preview) }
                try await check.value
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    worker.queue.async {
                        do {
                            try self.worker.flush()
                            if self.worker.store == nil {
                                guard let zone = TimeZone(identifier: zoneName) else { throw HistoryError.invalid }
                                self.worker.store = try UsageHistoryStore(root: self.worker.root, zone: zone)
                            }
                            self.worker.importID = id
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                for offset in stride(from: 0, to: preview.events.count, by: 50) {
                    try Task.checkCancellation()
                    let batch = Array(preview.events[offset..<min(offset + 50, preview.events.count)])
                    let count: Int = try await withCheckedThrowingContinuation { continuation in
                        worker.queue.async {
                            do {
                                guard self.worker.importID == id, let store = self.worker.store else {
                                    throw CancellationError()
                                }
                                continuation.resume(returning: try store.record(batch, importing: true))
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    committed += count
                    if importGeneration == id { importStatus = "\(committed) new calls saved" }
                }
                if importGeneration == id {
                    importPreview = nil
                    importStatus = "Imported \(committed) new calls. Coverage remains partial; live recording settings were not changed."
                }
            } catch {
                if importGeneration == id {
                    importStatus = "\(committed) new calls saved. " +
                        (error is CancellationError ? "Import cancelled; retrying will not duplicate saved calls." : importFailure(error))
                }
            }
            if importGeneration == id {
                importBusy = false
                revision += 1
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        worker.queue.async { self.worker.importID = nil }
    }

    func discardImportPreview() {
        cancelImport()
        importGeneration = UUID()
        importPreview = nil
        importNewCalls = 0
        importStatus = nil
        importBusy = false
    }

    private func importFailure(_ error: Error) -> String {
        (error as? TelemetryError)?.rawValue ?? (error as? HistoryError)?.rawValue
            ?? (error as? TokenotchError)?.rawValue ?? TelemetryError.unsupported.rawValue
    }

    func deleteAll() {
        discardImportPreview()
        navigation = nil
        clearNotchSummary()
        generation = UUID()
        let id = generation
        outstanding = 0
        recording = false
        status = "Deleting usage history"
        worker.queue.async {
            self.worker.active = false
            self.worker.pending = []
            self.worker.importID = nil
            do {
                if let store = self.worker.store { try store.delete() }
                else { try UsageHistoryStore.removeArchive(root: self.worker.root) }
                self.worker.store = nil
                self.worker.needsGap = false
                Task { @MainActor in
                    guard self.generation == id else { return }
                    self.revision += 1
                    self.configure()
                }
            } catch {
                Task { @MainActor in
                    guard self.generation == id else { return }
                    self.report(error)
                }
            }
        }
    }

    func stop() {
        cancelImport()
        started = false
        summaryTask?.cancel()
        worker.queue.sync {
            do { try worker.stop(now: Date()) }
            catch { log.error("Usage history shutdown flush failed; the recording interval may be partial.") }
        }
    }

    private func report(_ failure: Error) {
        clearNotchSummary()
        failed = true
        recording = false
        outstanding = 0
        error = (failure as? HistoryError)?.rawValue
            ?? (failure as? TokenotchError)?.rawValue ?? HistoryError.storage.rawValue
        status = "History unavailable; recording paused"
        log.error("Usage history unavailable; existing data was not reset.")
    }

    private func clearNotchSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryKey = nil
        notchSummary = nil
        comparison = nil
        selectedEvidence = nil
        todayUsage = nil
        notchUsage = nil
        notchTimeline = nil
        notchAnchor = nil
        notchLoading = true
    }

    private func readComparison(now: Date, calendar: HistoryCalendar, range: HistoryRange) async throws
        -> (HistorySnapshot?, HistoryInsightComparison?, HistorySnapshot?, HistorySnapshot?, UsageTimeline?) {
        let source = selectedSource
        return try await withCheckedThrowingContinuation { continuation in
            worker.queue.async {
                do {
                    try self.worker.flush()
                    guard let store = self.worker.store else {
                        continuation.resume(returning: (nil, nil, nil, nil, nil))
                        return
                    }
                    let periods = HistoryInsightComparison.periods(now: now, calendar: calendar)
                    let summary = try store.query(NotchHistorySummary.interval(now: now, calendar: calendar), source: source)
                    let comparison = try HistoryInsightComparison(current: store.query(periods.0, source: source),
                        previous: store.query(periods.1, source: source), now: now)
                    let today = try store.query(calendar.interval(.today, selected: now, now: now), source: source)
                    let usage = try range == .today ? today
                        : store.query(calendar.interval(range, selected: now, now: now), source: source)
                    if range == .week { try store.pruneHourlyHistory(now: now) }
                    let timeline = try range == .today
                        ? store.hourlyTimeline(now: now, source: source) : UsageTimeline.week(snapshot: usage, now: now)
                    continuation.resume(returning: (summary, comparison, today, usage, timeline))
                } catch {
                    self.worker.fail(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func refreshNotchSummary(now: Date) {
        guard started, !failed else { return }
        guard let timeZone = TimeZone(identifier: zone) else {
            report(HistoryError.invalid)
            return
        }
        let calendar = HistoryCalendar(zone: timeZone)
        let key = "\(generation)|\(revision)|\(zone)|\(calendar.hour(containing: now).start)|\(notchRange.rawValue)|\(selectedSource?.rawValue ?? "all")"
        guard summaryKey != key else { return }
        if let notchAnchor, calendar.key(notchAnchor) != calendar.key(now) {
            todayUsage = nil
            notchUsage = nil
            notchTimeline = nil
            notchLoading = true
        }
        summaryTask?.cancel()
        summaryKey = key
        let id = generation
        let range = notchRange
        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (snapshot, comparison, today, usage, timeline) = try await self.readComparison(now: now, calendar: calendar, range: range)
                try Task.checkCancellation()
                guard self.generation == id, self.summaryKey == key else { return }
                self.notchSummary = try snapshot.map { try NotchHistorySummary(snapshot: $0, now: now) }
                self.comparison = comparison
                self.todayUsage = today
                self.notchUsage = usage
                self.notchTimeline = timeline
                self.notchAnchor = now
                self.notchLoading = false
            } catch is CancellationError {
                // A newer revision or lifecycle transition owns the summary.
            } catch {
                guard !Task.isCancelled, self.generation == id, self.summaryKey == key else { return }
                self.report(error)
            }
        }
    }
}
