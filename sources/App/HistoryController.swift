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

struct HistoryQueryScope {
    let provider: UsageProvider?
    let source: UsageSource?
}

// Mutable state is confined to queue; callbacks only publish on the main actor.
private final class HistoryWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.rottathiago.tokenotch.history", qos: .utility)
    let root: URL
    var store: UsageHistoryStore?
    var active = false
    var windows = RecordingWindows<UsageSource>()
    var lastHeartbeat = Date()
    var pending: [(id: UUID, event: ActivityEvent)] = []
    var flushScheduled = false
    var needsGap = false
    var sources: Set<UsageSource> { windows.keys }
    var importID: UUID?
    var onCommit: (([UUID]) -> Void)?
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
        try store.record(batch.map(\.event))
        pending.removeAll(keepingCapacity: true)
        onCommit?(batch.map(\.id))
    }
    func accept(_ event: ActivityEvent, id: UUID) {
        guard active, windows.accepts(event.usageSource, at: event.timestamp) else { onCommit?([id]); return }
        pending.append((id, event))
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
        windows.update([], at: now)
        lastHeartbeat = now
    }
    func configure(sources: Set<UsageSource>, now: Date) throws {
        try flush()
        let previous = windows.keys
        if active {
            let retained = previous.intersection(sources)
            let removed = previous.subtracting(sources)
            if !retained.isEmpty { try store?.heartbeat(from: lastHeartbeat, to: now, active: true, sources: retained) }
            if !removed.isEmpty { try store?.heartbeat(from: lastHeartbeat, to: now, active: false, sources: removed) }
        }
        let added = sources.subtracting(previous)
        if !added.isEmpty { try store?.heartbeat(from: now, to: now, active: true, sources: added) }
        windows.update(sources, at: now)
        active = !sources.isEmpty
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
    @Published private(set) var recordingSources: Set<UsageSource> = []
    var recordingProviders: Set<UsageProvider> { Set(recordingSources.map(\.provider)) }
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
    @Published private(set) var knownProviders: Set<UsageProvider> = []
    @Published var selectedProvider: UsageProvider? = .copilot {
        didSet {
            guard selectedProvider != oldValue else { return }
            if let selectedSource, let selectedProvider, selectedSource.provider != selectedProvider {
                self.selectedSource = nil
            }
            clearNotchSummary()
            refreshNotchSummary(now: Date())
        }
    }
    @Published var selectedSource: UsageSource? {
        didSet {
            guard selectedSource != oldValue else { return }
            if let selectedSource, let selectedProvider, selectedSource.provider != selectedProvider {
                self.selectedProvider = selectedSource.provider
            }
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
    private var outstanding = Set<UUID>()
    private var failed = false
    private let log = Logger(subsystem: "io.github.rottathiago.tokenotch", category: "history")

    init(defaults: UserDefaults, root: URL) {
        self.defaults = defaults
        worker = HistoryWorker(root: root)
        ProviderRecordingConsent.migrateCopilot(in: defaults)
        enabled = ProviderRecordingConsent.enabled(.usageHistory, provider: .copilot, in: defaults)
        zone = defaults.string(forKey: "usageHistoryZone") ?? TimeZone.current.identifier
        worker.onCommit = { [weak self] ids in
            Task { @MainActor in
                guard let self else { return }
                let committed = self.outstanding.intersection(ids)
                self.outstanding.subtract(ids)
                if self.started && !committed.isEmpty { self.revision += 1 }
            }
        }
    }

    func start(available: Bool) {
        started = true
        self.available = available
        availableSources = available ? [.cli] : []
        configure()
    }
    func setEnabled(_ value: Bool, provider: UsageProvider = .copilot) {
        if provider == .copilot { enabled = value }
        ProviderRecordingConsent.setEnabled(value, kind: .usageHistory, provider: provider, in: defaults)
        if value, defaults.string(forKey: "usageHistoryZone") == nil {
            zone = TimeZone.current.identifier
            defaults.set(zone, forKey: "usageHistoryZone")
        }
        configure()
    }
    func isEnabled(_ provider: UsageProvider) -> Bool {
        ProviderRecordingConsent.enabled(.usageHistory, provider: provider, in: defaults)
    }
    var selectionEnabled: Bool {
        if let provider = selectedSource?.provider ?? selectedProvider { return isEnabled(provider) }
        return UsageProvider.allCases.contains { isEnabled($0) }
    }
    var selectionRecording: Bool {
        recordingSources.contains {
            (selectedProvider == nil || $0.provider == selectedProvider) && (selectedSource == nil || $0 == selectedSource)
        }
    }
    func setAvailable(_ value: Bool) {
        var sources = availableSources
        if value { sources.insert(.cli) } else { sources.remove(.cli) }
        setAvailableSources(sources)
    }
    func setAvailableSources(_ sources: Set<UsageSource>) {
        guard availableSources != sources else { return }
        availableSources = sources
        available = sources.contains { $0.provider == .copilot }
        configure()
    }
    func retry() { configure() }

    func markGap(sources: Set<UsageSource>) {
        let sources = sources.intersection(recordingSources)
        guard !sources.isEmpty else { return }
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

    private func configure(refreshPresentation: Bool = true) {
        if refreshPresentation || failed { clearNotchSummary() }
        let id = UUID()
        generation = id
        failed = false
        error = nil
        let enabledProviders = Set(UsageProvider.allCases.filter {
            ProviderRecordingConsent.enabled(.usageHistory, provider: $0, in: defaults)
        })
        let wantsHistory = !enabledProviders.isEmpty
        let zoneName = zone
        let sources = availableSources.filter { enabledProviders.contains($0.provider) }
        recordingSources.formIntersection(sources)
        recording = recordingSources.contains { $0.provider == .copilot }
        let collect = sources.contains { $0.provider == .copilot }
        status = enabled ? (available ? "Starting history recording" : "Paused: connect a usage source") : "History paused; saved data is retained"
        worker.queue.async { [self] in
            do {
                let now = Date()
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
                    self.worker.windows.update([], at: now)
                }
                self.worker.onError = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.report(error)
                    }
                }
                try self.worker.configure(sources: sources, now: now)
                let savedZone = self.worker.store?.clock.calendar.timeZone.identifier
                let savedProviders = Set(try self.worker.store?.recordingCoverage().sources.map(\.provider) ?? [])
                Task { @MainActor in
                    guard self.generation == id else { return }
                    if let savedZone { self.zone = savedZone }
                    self.recording = collect
                    self.recordingSources = sources
                    self.knownProviders = savedProviders.union(self.availableSources.map(\.provider))
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
        guard !event.kind.isAttention, recordingSources.contains(event.usageSource), !failed else { return }
        guard outstanding.count < 256 else {
            report(HistoryError.queueFull)
            worker.queue.async {
                do {
                    let sources = self.worker.sources
                    try self.worker.stop(now: Date())
                    try self.worker.store?.markGap(at: Date(), sources: sources)
                } catch { self.worker.fail(error) }
            }
            return
        }
        let id = UUID()
        outstanding.insert(id)
        worker.queue.async { self.worker.accept(event, id: id) }
    }

    func tick(now: Date) {
        guard !recordingSources.isEmpty, !failed else {
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

    func read(_ interval: DateInterval, model: String?, provider: UsageProvider? = nil,
              scope: HistoryQueryScope? = nil) async throws -> HistorySnapshot? {
        try Task.checkCancellation()
        let selection = scope ?? HistoryQueryScope(provider: provider ?? selectedProvider, source: selectedSource)
        return try await withCheckedThrowingContinuation { continuation in
            worker.queue.async {
                do {
                    try self.worker.flush()
                    continuation.resume(returning: try self.worker.store?.query(interval, model: model,
                        source: selection.source, provider: selection.provider))
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
        outstanding.removeAll()
        recording = false
        recordingSources = []
        status = "Deleting usage history"
        worker.queue.async {
            self.worker.active = false
            self.worker.windows.update([], at: Date())
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

    func delete(provider: UsageProvider) {
        discardImportPreview()
        navigation = nil
        clearNotchSummary()
        recordingSources = recordingSources.filter { $0.provider != provider }
        worker.queue.async {
            do {
                try self.worker.flush()
                try self.worker.store?.delete(provider: provider)
                self.worker.windows.update(self.worker.sources.filter { $0.provider != provider }, at: Date())
                Task { @MainActor in
                    self.revision += 1
                    self.configure()
                }
            } catch { self.worker.fail(error) }
        }
    }

    func stop() {
        cancelImport()
        started = false
        recording = false
        recordingSources = []
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
        recordingSources = []
        outstanding.removeAll()
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
        let provider = selectedProvider
        return try await withCheckedThrowingContinuation { continuation in
            worker.queue.async {
                do {
                    try self.worker.flush()
                    guard let store = self.worker.store else {
                        continuation.resume(returning: (nil, nil, nil, nil, nil))
                        return
                    }
                    let periods = HistoryInsightComparison.periods(now: now, calendar: calendar)
                    let summary = try store.query(NotchHistorySummary.interval(now: now, calendar: calendar), source: source, provider: provider)
                    let comparison = try HistoryInsightComparison(current: store.query(periods.0, source: source, provider: provider),
                        previous: store.query(periods.1, source: source, provider: provider), now: now)
                    let today = try store.query(calendar.interval(.today, selected: now, now: now), source: source, provider: provider)
                    let usage = try range == .today ? today
                        : store.query(calendar.interval(range, selected: now, now: now), source: source, provider: provider)
                    if range == .week { try store.pruneHourlyHistory(now: now) }
                    let timeline = try range == .today
                        ? store.hourlyTimeline(now: now, source: source, provider: provider) : UsageTimeline.week(snapshot: usage, now: now)
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
        let key = "\(generation)|\(revision)|\(zone)|\(calendar.hour(containing: now).start)|\(notchRange.rawValue)|\(selectedProvider?.rawValue ?? "all")|\(selectedSource?.rawValue ?? "all")"
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
