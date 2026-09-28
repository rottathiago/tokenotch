import Combine
import Foundation
import TokenotchCore
import os

private final class TimelineWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.rottathiago.tokenotch.timeline", qos: .utility)
    let root: URL
    var store: SessionTimelineStore?
    var clients = Set<Client>()
    var since = Date.distantFuture
    var retention = TimelineRetention.seven
    var pending: [ActivityEvent] = []
    var scheduled = false
    var needsGap = false
    var commit: ((Int) -> Void)?
    var failure: ((Error) -> Void)?
    init(root: URL) { self.root = root }
    func fail(_ error: Error) {
        pending.removeAll()
        clients.removeAll()
        needsGap = true
        failure?(error)
    }
    func flush() throws {
        guard !pending.isEmpty else { return }
        guard let store else { throw TimelineError.storage }
        try store.record(pending, retention: retention)
        let count = pending.count
        pending.removeAll(keepingCapacity: true)
        commit?(count)
    }
    func accept(_ event: ActivityEvent) {
        guard clients.contains(event.source), event.timestamp >= since else { commit?(1); return }
        pending.append(event)
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
    @Published private(set) var error: String?
    @Published private(set) var status = "Off. Nothing is saved."
    @Published private(set) var archive: TimelineStatus?
    @Published private(set) var sessions: [TimelineSession] = []
    @Published private(set) var revision = 0
    @Published var selectedSession: String?
    private let defaults: UserDefaults
    private let worker: TimelineWorker
    private var clients = Set<Client>()
    private var started = false
    private var generation = UUID()
    private var outstanding = 0
    private var refreshTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.rottathiago.tokenotch", category: "timeline")

    init(defaults: UserDefaults, root: URL) {
        self.defaults = defaults
        worker = TimelineWorker(root: root)
        enabled = defaults.bool(forKey: "sessionTimelineEnabled")
        retention = TimelineRetention(rawValue: defaults.integer(forKey: "sessionTimelineRetention")) ?? .seven
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
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "sessionTimelineEnabled")
        configure()
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
        outstanding = 0
        recording = false
        error = nil
        let activeClients = enabled ? clients : []
        let wantsArchive = enabled
        let keep = retention
        status = enabled ? "Starting recording" : "Paused. Saved timelines are kept."
        worker.queue.async { [self] in
            do {
                let wasActive = !worker.clients.isEmpty
                try worker.flush()
                if worker.store == nil {
                    let exists = FileManager.default.fileExists(atPath: worker.root.appendingPathComponent("timeline/sessions.sqlite").path)
                    if wantsArchive || exists { worker.store = try SessionTimelineStore(root: worker.root) }
                }
                worker.retention = keep
                try worker.store?.maintain(retention: keep)
                try worker.store?.recording(!activeClients.isEmpty, interrupted: worker.needsGap || wasActive)
                worker.needsGap = false
                worker.since = Date()
                worker.clients = activeClients
                worker.commit = { [weak self] count in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.outstanding = max(0, self.outstanding - count)
                        self.refresh()
                    }
                }
                worker.failure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.report(error)
                    }
                }
                Task { @MainActor in
                    guard generation == id else { return }
                    recording = !activeClients.isEmpty
                    status = recording ? "Recording new sessions"
                        : enabled ? "Waiting for Copilot CLI or VS Code to connect" : "Paused. Saved timelines are kept."
                    refresh()
                }
            } catch {
                worker.clients.removeAll()
                Task { @MainActor in
                    guard generation == id else { return }
                    report(error)
                }
            }
        }
    }
    func observe(_ event: ActivityEvent) {
        guard !event.kind.isActivitySnapshot, !event.kind.isAttention,
              recording, error == nil, clients.contains(event.source) else { return }
        guard outstanding < 256 else {
            report(TimelineError.queueFull)
            worker.queue.async {
                self.worker.clients.removeAll()
                self.worker.needsGap = true
                do {
                    try self.worker.flush()
                    try self.worker.store?.recording(false, interrupted: true)
                } catch { self.worker.fail(error) }
            }
            return
        }
        outstanding += 1
        worker.queue.async { self.worker.accept(event) }
    }
    func tick(now: Date) {
        guard started, error == nil else { return }
        worker.queue.async {
            do {
                try self.worker.flush()
                try self.worker.store?.maintain(retention: self.worker.retention, now: now)
                if !self.worker.clients.isEmpty { try self.worker.store?.heartbeat(now: now) }
                Task { @MainActor in self.refresh() }
            } catch { self.worker.fail(error) }
        }
    }
    func markInterruption() {
        guard recording else { return }
        worker.queue.async {
            do { try self.worker.store?.recording(true, interrupted: true) }
            catch { self.worker.fail(error) }
        }
    }
    func readEvents(session: String, after: TimelineEvent? = nil) async throws -> TimelinePage? {
        try await read { try $0.events(session: session, after: after) }
    }
    func openSession(source: Client, hash: String) {
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
        let offset = sessions.count
        do {
            let next = try await read { try $0.sessions(offset: offset) }
            guard id == generation, sessions.count == offset else { return }
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
        refreshTask = Task {
            do {
                let result = try await read { store in
                    var sessions: [TimelineSession] = []
                    for page in 0..<pageCount { sessions += try store.sessions(offset: page * 100) }
                    return (try store.status(), sessions)
                }
                try Task.checkCancellation()
                guard id == generation else { return }
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
        outstanding = 0
        selectedSession = nil
        sessions = []
        archive = nil
        revision += 1
        status = "Deleting saved session timelines"
        worker.queue.async {
            self.worker.clients.removeAll()
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
    func stop() {
        started = false
        recording = false
        generation = UUID()
        outstanding = 0
        refreshTask?.cancel()
        worker.queue.sync {
            do {
                try worker.flush()
                try worker.store?.recording(false, interrupted: !worker.clients.isEmpty)
                worker.clients.removeAll()
            } catch { log.error("Timeline shutdown flush failed; observations may be missing.") }
        }
    }
    private func report(_ failure: Error) {
        refreshTask?.cancel()
        recording = false
        outstanding = 0
        error = (failure as? TimelineError)?.rawValue ?? (failure as? TokenotchError)?.rawValue ?? TimelineError.storage.rawValue
        status = "Session timelines unavailable; recording paused"
        log.error("Session timelines unavailable; saved data was not reset.")
    }
}
