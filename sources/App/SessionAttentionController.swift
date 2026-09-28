import Combine
import Foundation
import TokenotchCore
import os

struct SessionDetailTarget: Equatable, Identifiable {
    let source: Client
    let noticeSessionID: String
    var liveHash: String?
    var id: String { "\(source.rawValue):\(noticeSessionID)" }
}

@MainActor
final class SessionAttentionController: ObservableObject {
    @Published private(set) var state = SessionAttentionState()
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var heldNoticeIDs = Set<String>()
    private let defaults: UserDefaults
    private let root: URL
    private var readable = true
    private var restoredIDs = Set<String>()
    private let log = Logger(subsystem: "io.github.rottathiago.tokenotch", category: "session-notices")
    private var file: URL { root.appendingPathComponent("session-notices.json") }

    init(defaults: UserDefaults, root: URL) {
        self.defaults = defaults
        self.root = root
    }

    func start(now: Date = Date()) {
        saving = defaults.bool(forKey: "rememberSessionNotices")
        guard saving else { return }
        load(now: now)
    }

    private func load(now: Date) {
        do {
            try PrivateFiles.directory(root)
            if let data = try PrivateFiles.read(file, limit: 2 * 1_048_576) {
                var saved = try JSONDecoder().decode(SessionAttentionState.self, from: data)
                try saved.validate()
                saved.prune(now: now)
                state = saved
                restoredIDs = Set(saved.notices.map(\.id))
            }
            readable = true
            error = nil
        } catch {
            readable = false
            fail("Saved session notices could not be read. Live notices still work. Retry or clear saved notices.")
        }
    }

    @discardableResult
    func observe(_ event: ActivityEvent, now: Date) -> SessionNotice? {
        do {
            var next = state
            guard try next.observe(event, now: now) else { return nil }
            state = next
            // A current matching observation revalidates only the evidence it actually reports.
            for notice in next.notices where notice.observedAt == event.timestamp &&
                notice.sessionID == next.sessionID(source: event.source, hash: event.session) {
                if event.kind == .context && notice.kind == .context ||
                    event.kind == .compaction && notice.kind == .compaction ||
                    SessionNoticeKind(eventKind: event.kind) == notice.kind {
                    restoredIDs.remove(notice.id)
                }
            }
            save()
            return next.notice(for: event)
        } catch {
            fail("A session notice could not be updated because its observation was invalid.")
            return nil
        }
    }

    func isRestored(_ notice: SessionNotice) -> Bool { restoredIDs.contains(notice.id) }

    func markViewed(_ ids: Set<String>, now: Date = Date(), holdUntilClose: Bool = false) {
        if holdUntilClose {
            heldNoticeIDs.formUnion(state.notices.filter { ids.contains($0.id) && $0.kind == .stopped }.map(\.id))
        }
        var next = state
        if next.markViewed(ids, now: now) { state = next; save() }
    }

    func closeCard() { heldNoticeIDs = [] }

    /// Treats notices a person looked at in the closed card as seen: stops are marked viewed,
    /// every other kind is also dismissed so its attention highlight clears.
    func acknowledge(_ ids: Set<String>, now: Date = Date()) {
        let pending = state.notices.filter { ids.contains($0.id) && $0.disposition == .pending }
        guard !pending.isEmpty else { return }
        var next = state
        var changed = next.markViewed(Set(pending.map(\.id)), now: now)
        let dismissible = Set(pending.filter { $0.kind != .stopped }.map(\.id))
        if !dismissible.isEmpty { changed = next.dismiss(dismissible) || changed }
        if changed { state = next; save() }
    }

    func dismiss(_ id: String) {
        var next = state
        if next.dismiss([id]) { state = next; save() }
    }

    func dismissRequests(_ ids: Set<String>, now: Date = Date()) {
        let requests = Set(state.notices.filter {
            ids.contains($0.id) && $0.kind.isRequest && $0.disposition == .pending
        }.map(\.id))
        guard !requests.isEmpty else { return }
        var next = state
        next.markViewed(requests, now: now)
        next.dismiss(requests)
        state = next
        save()
    }

    func remove(_ source: Client) {
        var next = state
        next.remove(source)
        state = next
        save()
    }

    func tick(now: Date) {
        var next = state
        next.prune(now: now)
        if next != state { state = next; save() }
    }

    // All ledger operations run serially on the main actor. Atomic writes complete
    // before a deletion can run; there are no queued writes that can restore it.
    private func save() {
        guard saving, readable else { return }
        do {
            try PrivateFiles.write(try JSONEncoder().encode(state), to: file)
            error = nil
        } catch {
            fail("Session notices are not being saved. Changes may not survive restart. Retry or clear saved notices.")
        }
    }

    func retry(now: Date = Date()) {
        if readable { save() }
        else { load(now: now) }
    }

    func enable() {
        guard !saving else { return }
        let fresh = SessionAttentionState()
        do {
            try PrivateFiles.directory(root)
            // Do not silently overwrite an orphaned or unsupported saved ledger.
            guard try PrivateFiles.read(file, limit: 2 * 1_048_576) == nil else {
                fail("Saved notices already exist. Clear saved notices before enabling a fresh collection.")
                return
            }
            try PrivateFiles.write(try JSONEncoder().encode(fresh), to: file)
            state = fresh
            heldNoticeIDs = []
            restoredIDs = []
            readable = true
            saving = true
            defaults.set(true, forKey: "rememberSessionNotices")
            error = nil
        } catch {
            fail("Session notice saving could not be enabled. No consent or existing data was changed.")
        }
    }

    func disableAndDelete() {
        do {
            try deleteFile()
            defaults.set(false, forKey: "rememberSessionNotices")
            saving = false
            readable = true
            error = nil
        } catch {
            fail("Saved session notices could not be deleted. Remember session notices remains enabled.")
        }
    }

    @discardableResult
    func clear() -> Bool {
        do {
            try deleteFile()
            state = SessionAttentionState()
            heldNoticeIDs = []
            restoredIDs = []
            readable = true
            error = nil
            if saving {
                try PrivateFiles.write(try JSONEncoder().encode(state), to: file)
            }
            return true
        } catch {
            fail("Session notice clearing could not finish. Check local storage and retry.")
            return false
        }
    }

    private func deleteFile() throws {
        try PrivateFiles.directory(root)
        // PrivateFiles checks ownership and rejects symlinks before targeted removal.
        if try PrivateFiles.read(file, limit: 2 * 1_048_576) != nil {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func fail(_ message: String) {
        error = message
        log.error("\(message, privacy: .public)")
    }
}
