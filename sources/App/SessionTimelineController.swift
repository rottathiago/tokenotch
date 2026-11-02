import Combine
import Foundation
import TokenotchCore
import os

private final class TimelineWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.rottathiago.tokenotch.timeline", qos: .utility)
    let root: URL
    var store: SessionTimelineStore?
    var windows = RecordingWindows<Client>()
    var clients: Set<Client> { windows.keys }
    var retention = TimelineRetention.seven
    var pending: [(id: UUID, event: ActivityEvent)] = []
    var scheduled = false
    var needsGap = false
    var commit: (([UUID]) -> Void)?
    var failure: ((Error) -> Void)?
    init(root: URL) { self.root = root }
    func fail(_ error: Error) {
        pending.removeAll()
        needsGap = true
        failure?(error)
    }
    func flush() throws {
        guard !pending.isEmpty else { return }
        guard let store else { throw TimelineError.storage }
        try store.record(pending.map(\.event), retention: retention)
        let ids = pending.map(\.id)
        pending.removeAll(keepingCapacity: true)
        commit?(ids)
    }
    func accept(_ event: ActivityEvent, id: UUID) {
        guard !needsGap, windows.accepts(event.source, at: event.timestamp) else { commit?([id]); return }
        pending.append((id, event))
        do {
            if pending.count >= 50 { try flush() }
            if !scheduled {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 1) {
                    self.scheduled = false
                    do { try self.flush() } catch { self.fail(error) }
                }
            }
        } catch { fail(error) }
    }
}

@MainActor
final class SessionTimelineController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var retention: TimelineRetention
    @Published private(set) var recording = false
    @Published private(set) var recordingClients: Set<Client> = []
    var recordingProviders: Set<UsageProvider> { Set(recordingClients.map(\.provider)) }
    @Published private(set) var error: String?
    @Published private(set) var status = "Off. Nothing is saved."
    @Published private(set) var archive: TimelineStatus?
    @Published private(set) var sessions: [TimelineSession] = []
    @Published private(set) var revision = 0
    @Published var selectedSession: String?
    @Published var selectedProvider: UsageProvider? = .copilot {
        didSet {
            guard oldValue != selectedProvider else { return }
            if let selectedClient, let selectedProvider, selectedClient.provider != selectedProvider { self.selectedClient = nil }
            clearSelection()
        }
    }
    @Published var selectedClient: Client? {
        didSet { if oldValue != selectedClient { clearSelection() } }
    }
    private let defaults: UserDefaults
    private let worker: TimelineWorker
    private var clients = Set<Client>()
    private var started = false
    private var generation = UUID()
    private var selectionGeneration = UUID()
    private var outstanding = Set<UUID>()
    private var refreshTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.rottathiago.tokenotch", category: "timeline")

    init(defaults: UserDefaults, root: URL) {
        self.defaults = defaults
        worker = TimelineWorker(root: root)
        ProviderRecordingConsent.migrateCopilot(in: defaults)
        enabled = ProviderRecordingConsent.enabled(.sessionTimeline, provider: .copilot, in: defaults)
        retention = TimelineRetention(rawValue: defaults.integer(forKey: "sessionTimelineRetention")) ?? .seven
        worker.commit = { [weak self] ids in
            Task { @MainActor in
                guard let self else { return }
                let committed = self.outstanding.intersection(ids)
                self.outstanding.subtract(ids)
                if !committed.isEmpty { self.refresh() }
            }
        }
    }
    func start(clients: Set<Client>) {
        started = true
        self.clients = clients
        configure()
    }
    func setAvailable(_ clients: Set<Client>) {
        guard self.clients != clients else { return }
        self.clients = clients
        configure()
    }
    func setEnabled(_ value: Bool, provider: UsageProvider = .copilot) {
        if provider == .copilot { enabled = value }
        ProviderRecordingConsent.setEnabled(value, kind: .sessionTimeline, provider: provider, in: defaults)
        configure()
    }
    func isEnabled(_ provider: UsageProvider) -> Bool {
        ProviderRecordingConsent.enabled(.sessionTimeline, provider: provider, in: defaults)
    }
    private func clearSelection() {
        selectionGeneration = UUID()
        refreshTask?.cancel()
        selectedSession = nil
        sessions = []
        archive = nil
        refresh()
    }
    func setRetention(_ value: TimelineRetention) {
        retention = value
        defaults.set(value.rawValue, forKey: "sessionTimelineRetention")
        configure()
    }
    func retry() { configure() }
    private func configure() {
        guard started else { return }
        generation = UUID()
        let id = generation
        refreshTask?.cancel()
        error = nil
        let enabledProviders = Set(UsageProvider.allCases.filter {
            ProviderRecordingConsent.enabled(.sessionTimeline, provider: $0, in: defaults)
        })
        let activeClients = clients.filter { enabledProviders.contains($0.provider) }
        recordingClients.formIntersection(activeClients)
        recording = recordingClients.contains { $0.provider == .copilot }
        let wantsArchive = !enabledProviders.isEmpty
        let keep = retention
        status = enabled ? "Starting recording" : "Paused. Saved timelines are kept."
        worker.queue.async { [self] in
            do {
                try worker.flush()
                if worker.store == nil {
                    let exists = FileManager.default.fileExists(atPath: worker.root.appendingPathComponent("timeline/sessions.sqlite").path)
                    if wantsArchive || exists { worker.store = try SessionTimelineStore(root: worker.root) }
                }
                worker.retention = keep
                try worker.store?.maintain(retention: keep)
                let previous = worker.clients
                let providers = Set(previous.union(activeClients).map(\.provider))
                for provider in providers {
                    let old = previous.filter { $0.provider == provider }
                    let new = activeClients.filter { $0.provider == provider }
                    if old != new || worker.needsGap {
                        try worker.store?.recording(!new.isEmpty, interrupted: !old.isEmpty, provider: provider)
                    }
                }
                if worker.needsGap { worker.windows.update([], at: Date()) }
                worker.needsGap = false
                worker.windows.update(activeClients, at: Date())
                worker.failure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.report(error)
                    }
                }
                Task { @MainActor in
                    guard generation == id else { return }
                    recordingClients = activeClients
                    recording = activeClients.contains { $0.provider == .copilot }
                    status = recording ? "Recording new sessions"
                        : enabled ? "Waiting for Copilot CLI or VS Code to connect" : "Paused. Saved timelines are kept."
                    refresh()
                }
            } catch {
                worker.needsGap = true
                Task { @MainActor in
                    guard generation == id else { return }
                    report(error)
                }
            }
        }
    }
    func observe(_ event: ActivityEvent) {
        guard !event.kind.isActivitySnapshot, !event.kind.isAttention,
              error == nil, recordingClients.contains(event.source) else { return }
        guard outstanding.count < 256 else {
            report(TimelineError.queueFull)
            worker.queue.async {
                self.worker.needsGap = true
                do {
                    try self.worker.flush()
                    for provider in Set(self.worker.clients.map(\.provider)) {
                        try self.worker.store?.recording(false, interrupted: true, provider: provider)
                    }
                } catch { self.worker.fail(error) }
            }
            return
        }
        let id = UUID()
        outstanding.insert(id)
        worker.queue.async { self.worker.accept(event, id: id) }
    }
    func tick(now: Date) {
        guard started, error == nil else { return }
        worker.queue.async {
            do {
                try self.worker.flush()
                try self.worker.store?.maintain(retention: self.worker.retention, now: now)
                if !self.worker.needsGap {
                    for provider in Set(self.worker.clients.map(\.provider)) {
                        try self.worker.store?.heartbeat(now: now, provider: provider)
                    }
                }
                Task { @MainActor in self.refresh() }
            } catch { self.worker.fail(error) }
        }
    }
    func markInterruption() {
        guard !recordingClients.isEmpty else { return }
        worker.queue.async {
            do {
                for provider in Set(self.worker.clients.map(\.provider)) {
                    try self.worker.store?.recording(true, interrupted: true, provider: provider)
                }
            }
            catch { self.worker.fail(error) }
        }
    }
    func readEvents(session: String, after: TimelineEvent? = nil) async throws -> TimelinePage? {
        try await read { try $0.events(session: session, after: after) }
    }
    func readStatus(provider: UsageProvider) async throws -> TimelineStatus? {
        try await read { try $0.status(provider: provider) }
    }
    func openSession(source: Client, hash: String) {
        selectedProvider = source.provider
        selectedClient = nil
        let id = generation
        Task {
            do {
                let session = try await read { $0.sessionID(source: source, hash: hash) }
                guard id == generation else { return }
                selectedSession = session
            } catch {
                guard id == generation else { return }
                report(error)
            }
        }
    }
    func loadMoreSessions() async {
        let id = generation
        let selection = selectionGeneration
        let offset = sessions.count
        let provider = selectedProvider, client = selectedClient
        do {
            let next = try await read { try $0.sessions(offset: offset, provider: provider, client: client) }
            guard id == generation, selection == selectionGeneration, sessions.count == offset else { return }
            let existing = Set(sessions.map(\.id))
            sessions += (next ?? []).filter { !existing.contains($0.id) }
        } catch {
            guard id == generation else { return }
            report(error)
        }
    }
    private func read<T>(_ body: @escaping (SessionTimelineStore) throws -> T) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            worker.queue.async {
                do {
                    try self.worker.flush()
                    continuation.resume(returning: try self.worker.store.map(body))
                } catch {
                    self.worker.fail(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func refresh() {
        guard started, error == nil else { return }
        refreshTask?.cancel()
        let id = generation
        let pageCount = max(1, (sessions.count + 99) / 100)
        let selection = selectionGeneration
        let provider = selectedProvider, client = selectedClient
        refreshTask = Task {
            do {
                let result = try await read { store in
                    var sessions: [TimelineSession] = []
                    for page in 0..<pageCount { sessions += try store.sessions(offset: page * 100, provider: provider, client: client) }
                    return (try store.status(provider: provider), sessions)
                }
                try Task.checkCancellation()
                guard id == generation, selection == selectionGeneration else { return }
                archive = result?.0
                sessions = result?.1 ?? []
                revision += 1
            } catch is CancellationError {
                // A newer lifecycle/commit owns publication.
            } catch {
                guard !Task.isCancelled, id == generation else { return }
                report(error)
            }
        }
    }
    func deleteAll() {
        generation = UUID()
        let id = generation
        refreshTask?.cancel()
        recording = false
        recordingClients = []
        outstanding.removeAll()
        selectedSession = nil
        sessions = []
        archive = nil
        revision += 1
        status = "Deleting saved session timelines"
        worker.queue.async {
            self.worker.windows.update([], at: Date())
            self.worker.pending.removeAll()
            do {
                if let store = self.worker.store { try store.delete() }
                else { try SessionTimelineStore.removeArchive(root: self.worker.root) }
                self.worker.store = nil
                self.worker.needsGap = false
                Task { @MainActor in
                    guard self.generation == id else { return }
                    self.configure()
                }
            } catch {
                self.worker.store = nil
                Task { @MainActor in
                    guard self.generation == id else { return }
                    self.report(error)
                }
            }
        }
    }
    func delete(provider: UsageProvider) {
        refreshTask?.cancel()
        selectedSession = nil
        sessions = []
        archive = nil
        recordingClients = recordingClients.filter { $0.provider != provider }
        worker.queue.async {
            do {
                try self.worker.flush()
                try self.worker.store?.delete(provider: provider)
                self.worker.windows.update(self.worker.clients.filter { $0.provider != provider }, at: Date())
                Task { @MainActor in self.configure() }
            } catch { self.worker.fail(error) }
        }
    }
    func stop() {
        started = false
        recording = false
        recordingClients = []
        generation = UUID()
        outstanding.removeAll()
        refreshTask?.cancel()
        worker.queue.sync {
            do {
                try worker.flush()
                for provider in Set(worker.clients.map(\.provider)) {
                    try worker.store?.recording(false, interrupted: true, provider: provider)
                }
                worker.windows.update([], at: Date())
            } catch { log.error("Timeline shutdown flush failed; observations may be missing.") }
        }
    }
    private func report(_ failure: Error) {
        refreshTask?.cancel()
        recording = false
        recordingClients = []
        outstanding.removeAll()
        error = (failure as? TimelineError)?.rawValue ?? (failure as? TokenotchError)?.rawValue ?? TimelineError.storage.rawValue
        status = "Session timelines unavailable; recording paused"
        log.error("Session timelines unavailable; saved data was not reset.")
    }
}
