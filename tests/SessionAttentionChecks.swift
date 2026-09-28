import AppKit
import Foundation
import TokenotchCore
import SwiftUI
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum SessionAttentionChecks {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NotchCheckFailure.failed(message) }
    }

    static func event(_ kind: EventKind, _ offset: Double = 0, session: String = "one",
                      source: Client = .cli, context: Int64 = 85, success: Bool? = nil) -> ActivityEvent {
        ActivityEvent(source: source, session: ActivityEvent.digest(session), kind: kind,
            timestamp: now.addingTimeInterval(offset),
            context: kind == .context ? ContextUsage(currentTokens: context, tokenLimit: 100) : nil,
            compaction: kind == .compaction ? CompactionUsage(success: success, after: success == true ? 20 : nil) : nil,
            metricID: kind == .compaction ? ActivityEvent.digest("metric-\(offset)") : nil)
    }

    static func lifecycle() throws {
        var state = SessionAttentionState()
        func feed(_ value: ActivityEvent) throws { try state.observe(value, now: value.timestamp) }
        try feed(event(.failed))
        let failure = state.notices[0]
        state.markViewed([failure.id], now: now)
        try feed(event(.active, 30))
        try feed(event(.idle, 60))
        try require(state.notices[0].needsHighlight && state.notices[0].viewedAt != nil,
                    "Viewing and heartbeat activity must not resolve errors")
        state.prune(now: now.addingTimeInterval(30 * 86_400))
        try require(state.notices[0].needsHighlight, "Unresolved errors do not expire with live sessions")
        try feed(event(.working, 90))
        try require(state.notices[0].disposition == .superseded, "Explicit new work supersedes errors")
        try feed(event(.failed, 100))
        state.markViewed([failure.id], now: now)
        try require(state.notices[0].viewedAt == nil, "Old acknowledgments cannot consume new errors")
        let count = state.receiptCount
        try feed(event(.failed, 100))
        try require(state.receiptCount == count, "Duplicate events are inert")

        try feed(event(.stopped, 110, session: "two"))
        let stop = state.notices.first { $0.kind == .stopped }!
        state.markViewed([stop.id], now: now)
        try require(!state.notices.first { $0.id == stop.id }!.needsHighlight, "Seen stops lose highlight")
        try feed(event(.stopped, 110, session: "two", source: .vscode))
        try require(Set(state.notices.filter { $0.kind == .stopped }.map(\.sessionID)).count == 2,
                    "Source-qualified identities cannot collide")
        try feed(event(.active, 120, session: "two"))
        try require(state.notices.first { $0.id == stop.id }?.disposition == .superseded,
                    "Later active work supersedes a stopped turn")

        try feed(event(.context, 1, session: "metrics"))
        let first = state.notices.first { $0.kind == .context }!
        state.dismiss([first.id])
        try feed(event(.context, 2, session: "metrics"))
        try require(state.notices.first { $0.id == first.id }?.disposition == .dismissed,
                    "Repeated high readings do not reannounce dismissed episodes")
        try feed(event(.context, 3, session: "metrics", context: 79))
        try feed(event(.context, 4, session: "metrics"))
        try require(state.notices.first { $0.kind == .context }?.id != first.id, "Recovery rearms later high context")
        try feed(event(.context, 2, session: "metrics", context: 1))
        try require(state.notices.first { $0.kind == .context }?.needsHighlight == true,
                    "Older evidence cannot resolve a later warning")
        try feed(event(.compaction, 5, session: "metrics", success: false))
        try feed(event(.compaction, 6, session: "metrics"))
        try feed(event(.active, 7, session: "metrics"))
        try require(state.notices.filter { $0.kind == .compaction && $0.needsHighlight }.count == 1,
                    "Compaction start and active snapshots are not recovery")
        try feed(event(.compaction, 6, session: "metrics", success: true))
        try require(state.notices.first { $0.kind == .compaction }?.disposition == .resolved,
                    "Equal-time completion follows a start")
        try require(state.notices.first { $0.kind == .context }?.disposition == .resolved,
                    "Reported lower post-compaction context resolves older high evidence")
        try feed(event(.failed, 8, session: "metrics"))
        try feed(event(.context, 9, session: "metrics"))
        try require(state.notices.first { $0.kind == .context }?.disposition != .pending,
                    "Metrics after terminal events cannot resurrect warnings")
        try feed(event(.context, session: "stale-limit"))
        try feed(event(.compaction, 301, session: "stale-limit", success: true))
        try require(state.notices.contains {
            $0.sessionID == state.sessionID(source: .cli, hash: ActivityEvent.digest("stale-limit")) &&
                $0.kind == .context && $0.needsHighlight
        }, "A stale context limit cannot establish recovery from compaction counts")

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(SessionAttentionState.self, from: data)
        try restored.validate()
        try require(restored.notices == state.notices, "Round-trip preserves notice dispositions")
        try require(!String(decoding: data, as: UTF8.self).contains(ActivityEvent.digest("metrics")),
                    "Raw bridge identity is never persisted")
        for index in 0..<105 { try feed(event(.failed, session: "limit-\(index)")) }
        try require(state.sessionCount == 100 && state.evictedSessions > 0, "Session state is bounded with disclosure")
        for index in 0..<4100 { try feed(event(.working, Double(index), session: "receipt-limit")) }
        try require(state.receiptCount == 4096, "Receipt cap is enforced exactly")
    }

    static func requests() throws {
        var state = SessionAttentionState()
        func feed(_ value: ActivityEvent) throws { try state.observe(value, now: value.timestamp) }
        let input = event(.inputRequested, 1)
        let approval = event(.approvalRequested, 1)
        try feed(event(.working))
        try feed(input)
        try feed(approval)
        try feed(event(.inputRequested, 1, session: "two"))
        try require(state.notices.filter(\.needsHighlight).count == 3, "Concurrent request kinds and sessions remain distinct")
        let first = state.notice(for: input)!
        state.markViewed([first.id], now: now)
        for (kind, offset) in [(EventKind.active, 2.0), (.idle, 3), (.stopped, 4)] {
            try feed(event(kind, offset))
        }
        try require(state.notices.first { $0.id == first.id }?.needsHighlight == true,
                    "Viewing, live work, idle and stopped do not prove that an input request was answered")
        let acceptedDuplicate = try state.observe(input, now: input.timestamp)
        try require(!acceptedDuplicate, "Duplicate request reports are inert")
        state.dismiss([first.id])
        try feed(event(.inputRequested, 5))
        let next = state.notice(for: event(.inputRequested, 5))!
        try require(next.id != first.id && next.viewedAt == nil && next.needsHighlight,
                    "A later request rearms after viewing or dismissal")
        try feed(event(.inputRequested, 2))
        try require(state.notices.contains { $0.id == next.id && $0.observedAt == now.addingTimeInterval(5) },
                    "Late requests cannot replace newer reports")
        try feed(event(.working, 6))
        try require(state.notices.filter { $0.sessionID == first.sessionID && $0.kind.isRequest }
            .allSatisfy { $0.disposition == .superseded }, "New prompt supersedes requests without claiming resolution")
        try feed(event(.approvalRequested, 5.5))
        try require(state.notices.filter { $0.sessionID == first.sessionID && $0.kind.isRequest }
            .allSatisfy { $0.disposition == .superseded }, "Old requests cannot cross a newer work boundary")
        try feed(event(.inputRequested, 7))
        try feed(event(.cancelled, 8))
        try feed(event(.inputRequested, 9))
        try require(state.notices.filter { $0.sessionID == first.sessionID && $0.kind.isRequest }
            .allSatisfy { $0.disposition == .superseded }, "Terminal outcomes supersede requests and bar resurrection")
        try require(state.notices.contains { $0.sessionID != first.sessionID && $0.needsHighlight },
                    "Another session's requests remain pending")
        for kinds in [[EventKind.inputRequested, .working], [.working, .inputRequested]] {
            var tied = SessionAttentionState()
            for kind in kinds { try tied.observe(event(kind), now: now) }
            try require(!tied.notices.contains(where: \.needsHighlight),
                        "Same-time prompt/request ambiguity does not invent a pending request")
        }

        var errors = SessionAttentionState()
        let error = event(.unrecoverableError)
        try errors.observe(error, now: now)
        let a = Notice.activity(error, sessionNotice: errors.notice(for: error))!
        let terminal = event(.failed, 1)
        try errors.observe(terminal, now: terminal.timestamp)
        let b = Notice.activity(terminal, sessionNotice: errors.notice(for: terminal))!
        try require(a.episodeID == b.episodeID && a.id != b.id, "Terminal and unrecoverable reports share an error episode")
        var preferences = NotificationPreferences()
        preferences.enabled = true
        var ledger = NotificationLedger()
        try require(ledger.evaluate(a, preferences: preferences, now: now) != nil, "First error episode notifies")
        try require(ledger.evaluate(b, preferences: preferences, now: terminal.timestamp) == nil, "No second alert at termination")
        ledger = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        try require(ledger.evaluate(Notice.activity(terminal)!, preferences: preferences, now: terminal.timestamp) == nil,
                    "Each coalesced report is consumed across restart even without a saved episode")
        try errors.observe(event(.working, 2), now: now.addingTimeInterval(2))
        let newError = event(.unrecoverableError, 3)
        try errors.observe(newError, now: newError.timestamp)
        let c = Notice.activity(newError, sessionNotice: errors.notice(for: newError))!
        try require(c.episodeID != a.episodeID && ledger.evaluate(c, preferences: preferences, now: newError.timestamp) != nil,
                    "Explicit new work rearms a later error")

        let request = Notice.activity(input, sessionNotice: first)!
        try require(!preferences.categories.contains(.attention), "Request category starts off")
        var muted = NotificationLedger()
        try require(muted.evaluate(request, preferences: preferences, now: now) == nil, "Request category requires consent")
        preferences.categories.insert(.attention)
        try require(muted.evaluate(request, preferences: preferences, now: now) == nil, "Category opt-in does not replay old requests")
        for mode in 0..<4 {
            var policy = preferences
            if mode == 0 { policy.enabled = false }
            if mode == 1 { policy.snoozedUntil = now.addingTimeInterval(60) }
            if mode == 2 { policy.quietEnabled = true; policy.quietEnd = policy.quietStart }
            var consumed = NotificationLedger()
            try require(consumed.evaluate(request, preferences: policy, now: now, managedMute: mode == 3) == nil,
                        "All request channels honor master, snooze, quiet time and managed mute")
            try require(consumed.evaluate(request, preferences: preferences, now: now.addingTimeInterval(61)) == nil,
                        "Suppressed requests never replay")
        }
        for index in 0..<4100 {
            _ = ledger.evaluate(Notice(id: "bound-\(index)", category: .failed, title: "", body: "",
                                       episodeID: "episode-\(index)"), preferences: preferences, now: now)
        }
        try require(ledger.consumed.count == 4096, "Episode aliases cannot exceed the receipt cap")
        let old = SessionAttentionState()
        guard var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any] else {
            throw NotchCheckFailure.failed("Expected a notice ledger object")
        }
        legacy["version"] = 1
        let migrated = try JSONDecoder().decode(SessionAttentionState.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(migrated.sessionID(source: .cli, hash: "same") == old.sessionID(source: .cli, hash: "same"),
                    "Legacy notice migration preserves pseudonymous identity")
        legacy["version"] = 99
        do {
            _ = try JSONDecoder().decode(SessionAttentionState.self, from: JSONSerialization.data(withJSONObject: legacy))
            throw NotchCheckFailure.failed("Unknown notice schemas must be rejected")
        } catch is SessionAttentionError {}
        var data = NotchPresentation(now: now)
        NotchChecks.applyAttention(state, to: &data)
        try require(data.activityTitle == "1 session requested attention" && data.needsAttention,
                    "Requests have priority over stopped/working rows and light the existing attention indicator")
    }

    static func notificationRouting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-request-routing-\(UUID().uuidString)")
        let suite = "tokenotch-request-routing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = TokenotchModel(defaults: defaults, root: root)
        var opened = 0
        model.openNotificationDetails = { opened += 1 }
        model.attention.observe(event(.inputRequested), now: now)
        model.attention.observe(event(.approvalRequested, session: "two"), now: now)
        let notice = model.attention.state.notices.first { $0.kind == .input }!
        let target = NoticeTarget(notice)
        model.settingsTab = .history
        model.routeNotification(target.userInfo)
        try require(model.selectedSession?.noticeSessionID == notice.sessionID && model.settingsTab == .usage && opened == 1,
                    "Notification selects its exact notice-only session and invokes the window owner")
        try require(model.attention.state.notices.allSatisfy { $0.viewedAt == nil },
                    "Routing alone cannot acknowledge unseen or newer notices")
        model.attention.observe(event(.inputRequested, 1), now: now)
        model.routeNotification(target.userInfo)
        try require(model.selectedSession?.noticeSessionID == notice.sessionID && model.notificationNavigationMessage != nil,
                    "Old notification for a retained session shows current details with an explicit stale-target message")
        try require(NoticeTarget(userInfo: ["source": "cli", "noticeSessionID": "/private/path", "noticeID": notice.id]) == nil,
                    "Routing never accepts an event-supplied path")
        try require(NoticeTarget(userInfo: ["source": "foreign", "noticeSessionID": notice.sessionID, "noticeID": notice.id]) == nil,
                    "Routing sources are allowlisted")
        model.routeNotification(["source": "cli"])
        try require(model.selectedSession == nil && model.notificationNavigationMessage != nil,
                    "Legacy or incomplete notification metadata has an explicit fallback")
        model.attention.enable()
        model.attention.observe(event(.approvalRequested, 2), now: now)
        let saved = NoticeTarget(model.attention.state.notices[0])
        let restored = TokenotchModel(defaults: defaults, root: root)
        restored.attention.start(now: now)
        restored.routeNotification(saved.userInfo)
        try require(restored.selectedSession?.noticeSessionID == saved.sessionID, "Saved notice targets survive a cold start")
        try require(restored.attention.clear(), "Clearing rotates notification target identity")
        restored.routeNotification(saved.userInfo)
        try require(restored.selectedSession == nil && restored.notificationNavigationMessage != nil,
                    "Cleared notification targets cannot open a different session")
    }

    static func persistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-notice-tests-\(UUID().uuidString)")
        let suite = "tokenotch-notice-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("session-notices.json")
        let controller = SessionAttentionController(defaults: defaults, root: root)
        controller.start(now: now)
        controller.observe(event(.failed), now: now)
        try require(!FileManager.default.fileExists(atPath: file.path), "Memory-only consent creates no ledger")
        controller.enable()
        try require(controller.saving && controller.state.notices.isEmpty, "Enabling starts fresh without backfill")
        controller.observe(event(.failed, 1), now: now)
        let id = controller.state.notices[0].id
        controller.markViewed([id], now: now)
        let restored = SessionAttentionController(defaults: defaults, root: root)
        restored.start(now: now)
        try require(restored.state.notices[0].viewedAt != nil && restored.state.notices[0].needsHighlight,
                    "Restart keeps viewed but unresolved notices")
        try require(restored.isRestored(restored.state.notices[0]), "Restored evidence is last-reported")
        restored.dismiss(id)
        let dismissed = SessionAttentionController(defaults: defaults, root: root)
        dismissed.start(now: now)
        try require(dismissed.state.notices[0].disposition == .dismissed, "Dismissal survives restart")
        dismissed.observe(event(.failed, 2, source: .vscode), now: now)
        dismissed.remove(.cli)
        try require(dismissed.state.notices.allSatisfy { $0.source == .vscode }, "Removal is source-specific")
        let oldKey = dismissed.state.sessionID(source: .cli, hash: "same")
        try require(dismissed.clear(), "Clear succeeds on private state")
        try require(dismissed.state.notices.isEmpty &&
                    dismissed.state.sessionID(source: .cli, hash: "same") != oldKey, "Clear rotates identity")
        dismissed.observe(event(.failed, 3), now: now)
        dismissed.disableAndDelete()
        try require(!dismissed.saving && !FileManager.default.fileExists(atPath: file.path)
                    && !dismissed.state.notices.isEmpty, "Opt-out removes disk state, not live notices")

        try PrivateFiles.write(Data("corrupt".utf8), to: file)
        defaults.set(true, forKey: "rememberSessionNotices")
        let broken = SessionAttentionController(defaults: defaults, root: root)
        broken.start(now: now)
        broken.observe(event(.failed, 4), now: now)
        try require(broken.error != nil && broken.state.notices.count == 1, "Read failure preserves honest memory-only behavior")
        let corrupt = try PrivateFiles.read(file)
        try require(corrupt == Data("corrupt".utf8), "Invalid ledgers are never silently replaced")
        try require(broken.clear(), "Explicit reset recovers a corrupt owned ledger")
        let target = root.appendingPathComponent("untouched")
        try PrivateFiles.write(Data("keep".utf8), to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        broken.disableAndDelete()
        let untouched = try PrivateFiles.read(target)
        try require(broken.saving && broken.error != nil && untouched == Data("keep".utf8),
                    "Unsafe deletion fails visibly and leaves the symlink target alone")
    }

    static func exposure() throws {
        var tracker = NotchInteraction.NoticeExposure()
        tracker.open(origin: .hover, initial: ["a", "hidden"])
        tracker.visibility("a", visible: true, generation: tracker.generation)
        try require(tracker.tick(now: now, windowVisible: true, engaged: true).viewed.isEmpty, "Dwell starts at real exposure")
        try require(tracker.tick(now: now.addingTimeInterval(0.99), windowVisible: true, engaged: true).viewed.isEmpty, "No early acknowledgment")
        try require(tracker.tick(now: now.addingTimeInterval(1), windowVisible: true, engaged: true).viewed == ["a"], "Only visible occurrence is read at one second")
        tracker.visibility("new", visible: true, generation: tracker.generation)
        try require(tracker.tick(now: now.addingTimeInterval(1.1), windowVisible: true, engaged: true).viewed.isEmpty, "New events get a new dwell")
        tracker.visibility("new", visible: false, generation: tracker.generation)
        try require(tracker.tick(now: now.addingTimeInterval(5), windowVisible: true, engaged: true).viewed.isEmpty, "Scrolling away cancels exposure")
        let old = tracker.generation
        tracker.close()
        tracker.open(origin: .deliberate, initial: ["a", "hidden"])
        tracker.visibility("hidden", visible: true, generation: old)
        tracker.visibility("a", visible: true, generation: tracker.generation)
        try require(tracker.tick(now: now, windowVisible: false, engaged: false).viewed.isEmpty, "Off-screen measurement is not viewing")
        try require(tracker.tick(now: now, windowVisible: true, engaged: false).viewed == ["a"], "Deliberate open reads rendered initial rows")
        tracker.visibility("later", visible: true, generation: tracker.generation)
        try require(tracker.tick(now: now.addingTimeInterval(10), windowVisible: true, engaged: false).viewed.isEmpty, "Pinned future events are not automatically seen")
        tracker.open(origin: .automatic, initial: ["a"])
        tracker.visibility("a", visible: true, generation: tracker.generation)
        try require(tracker.tick(now: now, windowVisible: true, engaged: false).viewed.isEmpty, "Automatic reveal is not human viewing")
        try require(tracker.tick(now: now.addingTimeInterval(5), windowVisible: true, engaged: false).viewed.isEmpty, "Automatic reveal stays unread")
    }

    static func requestExposure() throws {
        var tracker = NotchInteraction.NoticeExposure()
        func open(_ origin: NotchInteraction.NoticeExposure.Origin) {
            tracker.open(origin: origin, initial: ["input", "approval", "hidden", "error"])
            for id in ["input", "approval", "error"] {
                tracker.visibility(id, visible: true, generation: tracker.generation)
            }
        }
        func tick(_ offset: Double, engaged: Bool = false, visible: Bool = true,
                  requests: Set<String> = ["input", "approval", "hidden"]) -> NotchInteraction.NoticeExposure.Update {
            tracker.tick(now: now.addingTimeInterval(offset), windowVisible: visible,
                         engaged: engaged, pendingRequests: requests)
        }

        open(.deliberate)
        let initial = tick(0)
        try require(initial.viewed == ["input", "approval", "error"] && initial.dismiss.isEmpty,
                    "Deliberate opening views rows immediately without immediately dismissing requests")
        try require(tick(2.999).dismiss.isEmpty, "Requests cannot dismiss before three seconds")
        try require(tick(3).dismiss == ["input", "approval"], "Keyboard opening dismisses only visible requests at three seconds")
        try require(tick(4).dismiss.isEmpty, "A dwell emits each dismissal only once")
        tracker.visibility("hidden", visible: true, generation: tracker.generation)
        try require(tick(4).dismiss.isEmpty && tick(6.999).dismiss.isEmpty,
                    "A newly displayed request receives its own complete dwell")
        try require(tick(7).dismiss == ["hidden"], "Later visible requests count in a deliberately opened card")

        open(.hover)
        _ = tick(0, engaged: true)
        let viewed = tick(1, engaged: true)
        try require(viewed.viewed == ["input", "approval", "error"] && viewed.dismiss.isEmpty,
                    "One-second hover viewing must not dismiss or restart request dwell")
        try require(tick(2.999, engaged: true).dismiss.isEmpty &&
                    tick(3, engaged: true).dismiss == ["input", "approval"],
                    "Hover dismissal is three total seconds, not three seconds after being marked viewed")

        for interruption in ["scroll", "hidden", "disengaged"] {
            open(.hover)
            _ = tick(0, engaged: true)
            _ = tick(2, engaged: true)
            if interruption == "scroll" {
                for id in ["input", "approval"] {
                    tracker.visibility(id, visible: false, generation: tracker.generation)
                    tracker.visibility(id, visible: true, generation: tracker.generation)
                }
            } else {
                _ = tick(2, engaged: interruption != "disengaged", visible: interruption != "hidden")
            }
            try require(tick(3, engaged: true).dismiss.isEmpty && tick(5.999, engaged: true).dismiss.isEmpty,
                        "\(interruption) resets continuous request visibility")
            try require(tick(6, engaged: true).dismiss == ["input", "approval"],
                        "\(interruption) permits dismissal only after a fresh three seconds")
        }

        open(.automatic)
        try require(tick(0).dismiss.isEmpty && tick(10).dismiss.isEmpty, "Automatic display alone never dismisses requests")
        _ = tick(11, engaged: true)
        try require(tick(13.999, engaged: true).dismiss.isEmpty &&
                    tick(14, engaged: true).dismiss == ["input", "approval"],
                    "An automatic reveal begins dwell only after real engagement")

        open(.deliberate)
        _ = tick(0, visible: false)
        try require(tick(10, visible: false).dismiss.isEmpty, "Off-screen measurement and fade-in never count")
        _ = tick(11)
        try require(tick(13.999).dismiss.isEmpty && tick(14).dismiss == ["input", "approval"],
                    "Visible dwell starts after the card is revealed")

        open(.deliberate)
        _ = tick(0)
        let oldGeneration = tracker.generation
        tracker.open(origin: .automatic, initial: ["input", "approval"], keepingVisibility: true)
        tracker.visibility("input", visible: false, generation: oldGeneration)
        try require(tick(2.999).dismiss.isEmpty && tick(3).dismiss == ["input", "approval"],
                    "Repeated reveals preserve qualified dwell and reject stale callbacks")
        tracker.close()
        tracker.open(origin: .deliberate, initial: ["input"])
        tracker.visibility("input", visible: true, generation: oldGeneration)
        try require(tick(10).dismiss.isEmpty, "Old visibility cannot carry into a reopened card")
        tracker.visibility("input", visible: true, generation: tracker.generation)
        _ = tick(11)
        try require(tick(13.999).dismiss.isEmpty && tick(14).dismiss == ["input"], "Reopening requires a fresh dwell")

        open(.deliberate)
        _ = tick(0)
        try require(tick(3, requests: ["replacement"]).dismiss.isEmpty, "Removed or replaced requests cannot expire")
        tracker.visibility("replacement", visible: true, generation: tracker.generation)
        _ = tick(4, requests: ["replacement"])
        try require(tick(6.999, requests: ["replacement"]).dismiss.isEmpty &&
                    tick(7, requests: ["replacement"]).dismiss == ["replacement"],
                    "Replacement occurrences get new visibility and a new deadline")
    }

    static func requestDismissal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-request-dismissal-\(UUID().uuidString)")
        let suite = "tokenotch-request-dismissal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionAttentionController(defaults: defaults, root: root)
        controller.start(now: now)
        for kind in [EventKind.inputRequested, .approvalRequested, .failed, .context, .compaction, .stopped] {
            controller.observe(event(kind, session: kind.rawValue, success: kind == .compaction ? false : nil), now: now)
        }
        let requests = controller.state.notices.filter { $0.kind.isRequest }
        controller.dismissRequests(Set(controller.state.notices.map(\.id)), now: now)
        try require(controller.state.notices.filter { $0.kind.isRequest }
            .allSatisfy { $0.disposition == .dismissed && $0.viewedAt == now },
                    "Batch request dismissal records viewed and dismissed, never resolved")
        try require(controller.state.notices.filter { !$0.kind.isRequest }
            .allSatisfy { $0.disposition == .pending && $0.viewedAt == nil },
                    "The notch action cannot dismiss or mark viewed errors, warnings, or stopped notices")
        let file = root.appendingPathComponent("session-notices.json")
        try require(!FileManager.default.fileExists(atPath: file.path), "Memory-only dismissal creates no ledger")
        controller.observe(event(.inputRequested, 1, session: EventKind.inputRequested.rawValue), now: now)
        controller.dismissRequests(Set(requests.map(\.id)).union(["missing"]), now: now)
        try require(controller.state.notices.contains { $0.kind == .input && $0.disposition == .pending && $0.viewedAt == nil },
                    "Stale dismissal cannot consume a later request in the same session")
        let next = controller.state.notices.first { $0.kind == .input }!
        controller.observe(event(.working, 2, session: EventKind.inputRequested.rawValue), now: now)
        controller.dismissRequests([next.id], now: now)
        try require(controller.state.notices.first { $0.id == next.id }?.disposition == .superseded,
                    "Dismissal cannot rewrite a superseded request")

        controller.enable()
        controller.observe(event(.inputRequested, 3), now: now)
        controller.observe(event(.approvalRequested, 3), now: now)
        let savedIDs = Set(controller.state.notices.map(\.id))
        controller.dismissRequests(savedIDs, now: now)
        let restored = SessionAttentionController(defaults: defaults, root: root)
        restored.start(now: now)
        try require(restored.state.notices.count == 2 && restored.state.notices.allSatisfy {
            $0.disposition == .dismissed && $0.viewedAt == now
        }, "Request dismissal survives an opted-in restart")
        restored.observe(event(.approvalRequested, 4), now: now)
        let later = restored.state.notices.first { $0.kind == .approval }!
        try require(!savedIDs.contains(later.id) && later.needsHighlight, "Later requests rearm after saved dismissal")

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        restored.dismissRequests([later.id], now: now)
        try require(restored.error != nil && restored.state.notices.first { $0.id == later.id }?.disposition == .dismissed,
                    "Failed persistence leaves live dismissal working with an explicit error")
        try FileManager.default.removeItem(at: file)
        restored.retry(now: now)
        try require(restored.error == nil, "Dismissal persistence can be retried without losing live state")
    }

    static func presentation() throws {
        var state = SessionAttentionState()
        for (kind, name) in [(EventKind.stopped, "stop"), (.failed, "error"), (.context, "warning"), (.stopped, "extra")] {
            try state.observe(event(kind, session: name), now: now)
        }
        var data = NotchPresentation(now: now)
        NotchChecks.applyAttention(state, to: &data)
        try require(data.sessionRows.count == 3 && data.allSessionRows.count == 4, "Compact list is limited to three")
        try require(data.sessionSignal == .error && data.activityTitle == "1 session reported an error", "Errors have priority")
        let stop = state.notices.first { $0.kind == .stopped }!
        state.markViewed([stop.id], now: now)
        NotchChecks.applyAttention(state, to: &data)
        try require(!data.allSessionRows.contains { $0.notice?.id == stop.id }, "Viewed stop is absent after close")
        data.heldNoticeIDs = [stop.id]
        try require(data.allSessionRows.contains { $0.notice?.id == stop.id }, "Open-card stop stays stable")
        data.heldNoticeIDs = []
        for notice in state.notices { state.dismiss([notice.id]) }
        NotchChecks.applyAttention(state, to: &data)
        try require(data.sessionRows.isEmpty, "Dismissed notices leave the notch")
        for signal in [SessionSignal.error, .input, .approval, .warning, .stopped, .working, .idle, .unknown] {
            let color = NSColor(signal.color).usingColorSpace(.sRGB)!
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
            try require((luminance + 0.05) / 0.05 >= 4.5, "Session label colors meet text contrast on black")
        }
        try require(Set([SessionSignal.error, .input, .approval, .warning, .stopped, .working, .idle, .unknown].map(\.symbol)).count == 8,
                    "All states have distinct non-color symbols")
    }

    static func requestRowButtons() throws {
        var state = SessionAttentionState()
        for kind in [EventKind.inputRequested, .approvalRequested, .failed] {
            try state.observe(event(kind, session: kind.rawValue), now: now)
        }
        var data = NotchPresentation(now: now)
        NotchChecks.applyAttention(state, to: &data)
        for row in data.sessionRows {
            for scale in [0.75, 1.0, 1.5] {
                var opened: SessionDetailTarget?
                var dismissed: String?
                let content = CopilotSummaryContent(presentation: data, scale: scale,
                    openClient: { _ in }, openHistory: {},
                    openSession: { target, _ in opened = target }, dismissRequest: { dismissed = $0 })
                let width = (NotchLayout.cardWidth - 2 * NotchLayout.cardPadding) * scale
                let view = content.sessionRow(row).frame(width: width, height: 50 * scale)
                let panel = NotchPanel(contentRect: CGRect(x: 150, y: 150, width: width, height: 50 * scale))
                panel.acceptsKeyboardFocus = true
                let host = NSHostingView(rootView: view)
                panel.contentView = host
                panel.makeKeyAndOrderFront(nil)
                defer { panel.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                func click(x: CGFloat) throws {
                    try NotchChecks.click(panel, at: CGPoint(x: x, y: panel.frame.height / 2))
                }
                try click(x: width - NotchLayout.rowHeight * scale / 2)
                if row.notice?.kind.isRequest == true {
                    try require(dismissed == row.notice?.id && opened == nil,
                                "The scaled trailing checkmark dismisses exactly its request without opening the row")
                } else {
                    try require(dismissed == nil && opened == row.target,
                                "Non-request rows keep navigation across their full width")
                }
                dismissed = nil
                opened = nil
                try click(x: width / 2)
                try require(opened == row.target && dismissed == nil, "The row body remains a separate navigation button")
            }
        }
    }

    static func requestScrollVisibility() throws {
        var state = SessionAttentionState()
        try state.observe(event(.inputRequested), now: now)
        var data = NotchPresentation(now: now)
        NotchChecks.applyAttention(state, to: &data)
        let row = data.sessionRows[0]
        let id = row.notice!.id
        var exposure = NotchInteraction.NoticeExposure()
        exposure.open(origin: .deliberate, initial: [id])
        var visible = false
        let content = CopilotSummaryContent(presentation: data, openClient: { _ in }, openHistory: {},
            noticeVisibility: { notice, isVisible in
                visible = isVisible
                exposure.visibility(notice, visible: isVisible, generation: exposure.generation)
            })
        let view = ScrollView {
            VStack(spacing: 0) {
                content.sessionRow(row)
                Color.clear.frame(height: 500)
            }
        }.frame(width: NotchLayout.cardWidth, height: 120)
        let panel = NotchPanel(contentRect: CGRect(x: 100, y: 100, width: NotchLayout.cardWidth, height: 120))
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        try NotchChecks.waitUntil { visible }
        _ = exposure.tick(now: now, windowVisible: true, engaged: false, pendingRequests: [id])
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            throw NotchCheckFailure.failed("Request fixture has no scrollable document")
        }
        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scrollTo(document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY)
        try NotchChecks.waitUntil { !visible }
        try require(exposure.tick(now: now.addingTimeInterval(10), windowVisible: true, engaged: false,
                                  pendingRequests: [id]).dismiss.isEmpty,
                    "Real scroll visibility cancels dismissal for an off-screen request")
        scrollTo(document.isFlipped ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height)
        try NotchChecks.waitUntil { visible }
        _ = exposure.tick(now: now.addingTimeInterval(11), windowVisible: true, engaged: false, pendingRequests: [id])
        try require(exposure.tick(now: now.addingTimeInterval(13.999), windowVisible: true, engaged: false,
                                  pendingRequests: [id]).dismiss.isEmpty,
                    "Returning from a real scroll requires a fresh full dwell")
        try require(exposure.tick(now: now.addingTimeInterval(14), windowVisible: true, engaged: false,
                                  pendingRequests: [id]).dismiss == [id],
                    "The request dismisses after three seconds back in view")
    }

    static func requestHoverCard() throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw NotchCheckFailure.failed("Request hover checks require a display")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-request-hover-\(UUID().uuidString)")
        let suite = "tokenotch-request-hover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = TokenotchModel(defaults: defaults, root: root)
        model.clock = now
        model.options.displayID = screen.displayIdentifier
        model.options.edge = "right"
        var time = now
        var pointer = CGPoint(x: -100_000, y: -100_000)
        var settingsOpened = 0
        let fleet = NotchFleet(model: model, openSettings: { settingsOpened += 1 },
            isFullScreen: { _ in false }, pointerLocation: { pointer }, now: { time })
        let before = Set(app.windows.map(ObjectIdentifier.init))
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        model.attention.observe(event(.inputRequested, session: "hover-input"), now: now)
        model.attention.observe(event(.approvalRequested, session: "hover-approval"), now: now)
        let ids = Set(model.attention.state.notices.map(\.id))
        fleet.start()
        settle()
        guard let badge = app.windows.first(where: {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 is NotchPanel
        }) else { throw NotchCheckFailure.failed("No hoverable notch") }
        let pill = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: badge.frame.size),
                                        edge: .right, scale: 1, collapsed: true)
        pointer = CGPoint(x: badge.frame.minX + pill.midX, y: badge.frame.maxY - pill.midY)
        settle()
        time = now.addingTimeInterval(0.2)
        settle()
        guard let card = app.windows.first(where: {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible &&
                $0.contentView is ShapeHostingView<CopilotSummaryView>
        }), let host = card.contentView as? ShapeHostingView<CopilotSummaryView> else {
            throw NotchCheckFailure.failed("Pointer hover did not open the request card")
        }
        try require(Set(host.rootView.presentation.sessionRows.compactMap { $0.notice?.id }) == ids,
                    "Both attention requests must actually be displayed")
        pointer = CGPoint(x: card.frame.midX, y: card.frame.midY)
        settle()
        time = now.addingTimeInterval(1.2)
        settle()
        try require(model.attention.state.notices.allSatisfy { $0.viewedAt != nil && $0.disposition == .pending },
                    "Hover marks requests viewed without a click, but must not dismiss early")
        time = now.addingTimeInterval(3.199)
        settle()
        try require(model.attention.state.notices.allSatisfy { $0.disposition == .pending },
                    "Hover cannot dismiss before three continuous seconds")
        time = now.addingTimeInterval(3.2)
        try NotchChecks.waitUntil {
            model.attention.state.notices.allSatisfy { $0.disposition == .dismissed && $0.viewedAt != nil }
        }
        try require(card.isVisible && settingsOpened == 0 && model.selectedSession == nil,
                    "Three-second hover needs no click, checkmark, Settings navigation, or card closing")
        try require(!NotchPresentation(model: model).needsAttention,
                    "Automatically acknowledged requests must clear the attention indicator")

        time = now.addingTimeInterval(4.2)
        model.attention.observe(event(.inputRequested, 4, session: "hover-input"), now: time)
        settle()
        let next = model.attention.state.notices.first { $0.kind == .input }!
        try require(!ids.contains(next.id) && next.disposition == .pending,
                    "A later request rearms independently of the viewed occurrence")
        time = now.addingTimeInterval(7.199)
        settle()
        try require(model.attention.state.notices.first { $0.id == next.id }?.disposition == .pending,
                    "A new request needs its own full hover dwell")
        time = now.addingTimeInterval(7.2)
        try NotchChecks.waitUntil {
            model.attention.state.notices.first { $0.id == next.id }?.disposition == .dismissed
        }
    }

    static func requestCard() throws {
        let app = NSApplication.shared
        guard NSScreen.main != nil else { throw NotchCheckFailure.failed("Request card checks require a display") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-request-card-\(UUID().uuidString)")
        let suite = "tokenotch-request-card-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = TokenotchModel(defaults: defaults, root: root)
        model.clock = now
        model.options.foldsForFullScreen = true
        var time = now
        var fullScreen = false
        var settingsOpened = 0
        let fleet = NotchFleet(model: model, openSettings: { settingsOpened += 1 },
                               isFullScreen: { _ in fullScreen },
                               pointerLocation: { CGPoint(x: -100_000, y: -100_000) },
                               now: { time })
        let before = Set(app.windows.map(ObjectIdentifier.init))
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        func card() throws -> ShapeHostingView<CopilotSummaryView> {
            guard let host = app.windows.lazy.filter({
                !before.contains(ObjectIdentifier($0)) && $0.isVisible
            }).compactMap({ $0.contentView as? ShapeHostingView<CopilotSummaryView> }).first else {
                throw NotchCheckFailure.failed("No visible request card")
            }
            return host
        }
        for index in 0..<4 { model.attention.observe(event(.inputRequested, session: "request-\(index)"), now: now) }
        fleet.start()
        fleet.reveal(allowSettings: false)
        settle()
        time = now.addingTimeInterval(10)
        settle()
        try require(model.attention.state.notices.allSatisfy { $0.viewedAt == nil && $0.disposition == .pending },
                    "Real automatic card does not view or dismiss unattended requests")

        fleet.reveal(keyboard: true)
        settle()
        let host = try card()
        try require(host.window?.isKeyWindow == true, "Keyboard-opened request cards accept focus")
        let shown = Set(host.rootView.presentation.sessionRows.compactMap { $0.notice?.id })
        try require(shown.count == 3, "Only three session request rows are displayed")
        time = now.addingTimeInterval(12.999)
        settle()
        try require(model.attention.state.notices.allSatisfy { $0.disposition == .pending },
                    "The real card cannot dismiss before three seconds")
        time = now.addingTimeInterval(13)
        try NotchChecks.waitUntil {
            Set(model.attention.state.notices.filter { $0.disposition == .dismissed }.map(\.id)) == shown
        }
        settle()
        try require(host.window?.isVisible == true && settingsOpened == 0,
                    "Automatic dismissal preserves the card and never opens Settings")
        let remaining = model.attention.state.notices.first { $0.disposition == .pending }!
        try require(!shown.contains(remaining.id), "A previously hidden session keeps its own request")
        let selected = model.selectedSession
        let tab = model.settingsTab
        host.rootView.dismissRequest(remaining.id)
        try NotchChecks.waitUntil { model.attention.state.notices.allSatisfy { $0.disposition == .dismissed } }
        settle()
        try require(settingsOpened == 0 && model.selectedSession == selected && model.settingsTab == tab &&
                    host.window?.isVisible == true, "Inline dismissal cannot trigger session navigation or close the card")
        try require(!NotchPresentation(model: model).needsAttention &&
                    NotchPresentation(model: model).sessionRows.isEmpty,
                    "Dismissal removes request rows, request counts and the attention signal")

        time = now.addingTimeInterval(20)
        model.attention.observe(event(.inputRequested, 1, session: "paired"), now: now)
        model.attention.observe(event(.approvalRequested, 2, session: "paired"), now: now)
        settle()
        let paired = try card().rootView.presentation.sessionRows[0].notice!
        fleet.reveal(allowSettings: false)
        settle()
        time = now.addingTimeInterval(22.999)
        settle()
        try require(model.attention.state.notices.first { $0.id == paired.id }?.disposition == .pending,
                    "Repeated automatic reveals cannot dismiss the currently read request early")
        time = now.addingTimeInterval(23)
        try NotchChecks.waitUntil { model.attention.state.notices.first { $0.id == paired.id }?.disposition == .dismissed }
        settle()
        let second = try card().rootView.presentation.sessionRows[0].notice!
        try require(second.id != paired.id && second.sessionID == paired.sessionID && second.disposition == .pending,
                    "Dismissing one request exposes, but does not dismiss, another kind in the same session")
        time = now.addingTimeInterval(25.999)
        settle()
        try require(model.attention.state.notices.first { $0.id == second.id }?.disposition == .pending,
                    "A newly revealed same-session request gets a full three seconds")

        fullScreen = true
        fleet.reveal(allowSettings: false)
        time = now.addingTimeInterval(30)
        settle()
        try require(host.window?.isVisible != true &&
                    model.attention.state.notices.first { $0.id == second.id }?.disposition == .pending,
                    "Full-screen hiding cancels dismissal dwell without opening Settings")
        fullScreen = false
        fleet.reveal(keyboard: true)
        settle()
        time = now.addingTimeInterval(32.999)
        settle()
        try require(model.attention.state.notices.first { $0.id == second.id }?.disposition == .pending,
                    "Restoring the card starts a new full dwell")
        time = now.addingTimeInterval(33)
        try NotchChecks.waitUntil { model.attention.state.notices.first { $0.id == second.id }?.disposition == .dismissed }
        settle()
        let reopened = try card()
        try require(reopened.window?.isVisible == true, "An automatic reveal cannot unpin a deliberately opened card")

        model.attention.observe(event(.failed, session: "unchanged-error"), now: now)
        settle()
        let errorHost = try card()
        time = now.addingTimeInterval(40)
        settle()
        let error = model.attention.state.notices.first { $0.kind == .error }!
        try require(error.disposition == .pending, "Errors retain their existing unresolved behavior")
        let row = errorHost.rootView.presentation.sessionRows[0]
        errorHost.rootView.openSession(row.target, row.notice?.id)
        try require(settingsOpened == 1 && model.selectedSession == row.target && errorHost.window?.isVisible != true,
                    "The row body still navigates to the exact session details")
    }

    static func visibleCard() throws {
        let app = NSApplication.shared
        guard NSScreen.main != nil else { throw NotchCheckFailure.failed("Notice visibility checks require a display") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-notice-card-\(UUID().uuidString)")
        let suite = "tokenotch-notice-card-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = TokenotchModel(defaults: defaults, root: root)
        model.clock = now
        var pointer = CGPoint(x: -100_000, y: -100_000)
        let before = Set(app.windows.map(ObjectIdentifier.init))
        let fleet = NotchFleet(model: model, openSettings: {}, isFullScreen: { _ in false },
                               pointerLocation: { pointer })
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        for index in 0..<4 { model.attention.observe(event(.stopped, session: "card-\(index)"), now: now) }
        fleet.start()
        fleet.reveal(allowSettings: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        try require(model.attention.state.notices.allSatisfy { $0.viewedAt == nil }, "Automatic visible card cannot acknowledge")
        fleet.reveal(keyboard: true)
        try NotchChecks.waitUntil { model.attention.state.notices.contains { $0.viewedAt != nil } }
        try require(model.attention.state.notices.filter { $0.viewedAt != nil }.count == 3,
                    "Deliberate open acknowledges exactly the three rendered rows, not the hidden fourth")
        try require(model.attention.heldNoticeIDs.count == 3 &&
                    NotchPresentation(model: model).sessionRows.count == 3,
                    "Seen information stays in the open card")
        let detail = app.windows.first {
            !before.contains(ObjectIdentifier($0)) && $0.contentView is ShapeHostingView<CopilotSummaryView>
        }
        guard let host = detail?.contentView as? ShapeHostingView<CopilotSummaryView> else {
            throw NotchCheckFailure.failed("No live summary host")
        }
        let target = host.rootView.presentation.sessionRows[0].target
        host.rootView.openSession(target, nil)
        try require(model.selectedSession == target, "Notice-only session routes to its exact detail")
        try require(model.attention.heldNoticeIDs.isEmpty &&
                    NotchPresentation(model: model).sessionRows.count == 1,
                    "Closing removes viewed stops but leaves the unseen fourth")

        fleet.reveal(allowSettings: false)
        let remaining = model.attention.state.notices.first { $0.viewedAt == nil }!
        let panel = app.windows.first {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible &&
                $0.contentView is ShapeHostingView<CopilotSummaryView>
        }!
        pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        try NotchChecks.waitUntil { model.attention.state.notices.first { $0.id == remaining.id }?.viewedAt != nil }
        try require(model.attention.heldNoticeIDs.contains(remaining.id), "Real pointer dwell acknowledges visible information")
        let name = (0..<4).map { "card-\($0)" }.first {
            model.attention.state.sessionID(source: .cli, hash: ActivityEvent.digest($0)) == remaining.sessionID
        }!
        pointer = CGPoint(x: -100_000, y: -100_000)
        model.attention.observe(event(.stopped, 10, session: name), now: now)
        let next = model.attention.state.notices.first { $0.sessionID == remaining.sessionID }!
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try require(next.id != remaining.id &&
                    model.attention.state.notices.first { $0.id == next.id }?.viewedAt == nil,
                    "A new occurrence in an already visible row stays unread without engagement")
        pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        try NotchChecks.waitUntil { model.attention.state.notices.first { $0.id == next.id }?.viewedAt != nil }
        try require(model.attention.heldNoticeIDs.contains(next.id), "New occurrence receives its own real visibility callback")
    }

    static func closeAcknowledgment() throws {
        var tracker = NotchInteraction.NoticeExposure()
        func tick(_ offset: Double, engaged: Bool = true, visible: Bool = true) {
            _ = tracker.tick(now: now.addingTimeInterval(offset), windowVisible: visible,
                             engaged: engaged, pendingRequests: ["input"])
        }
        tracker.open(origin: .hover, initial: ["input", "error"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tracker.visibility("error", visible: true, generation: tracker.generation)
        tick(0); tick(0.49)
        try require(tracker.close().isEmpty, "An accidental swipe under half a second is not a visit")

        tracker.open(origin: .hover, initial: ["input", "error"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tracker.visibility("error", visible: true, generation: tracker.generation)
        tick(0); tick(0.5)
        try require(tracker.close() == ["input", "error"], "A half-second visit acknowledges every visible row on close")

        tracker.open(origin: .hover, initial: ["input", "error"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tick(0); tick(0.3, engaged: false); tick(1); tick(1.2)
        tracker.visibility("error", visible: true, generation: tracker.generation)
        tick(1.4)
        try require(tracker.close().isEmpty, "Only engaged, visible time counts toward a visit")

        tracker.open(origin: .hover, initial: ["input"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tick(0); tick(0.3)
        tracker.visibility("input", visible: false, generation: tracker.generation)
        tick(2)
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tick(2.1); tick(2.3)
        try require(tracker.close() == ["input"], "Scrolling away keeps exposure already earned")

        tracker.open(origin: .automatic, initial: ["input"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tick(0, engaged: false); tick(10, engaged: false)
        try require(tracker.close().isEmpty, "Untouched automatic pop-ups are never acknowledged")

        tracker.open(origin: .deliberate, initial: ["input"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tick(0, engaged: false)
        try require(tracker.close() == ["input"], "Deliberate opens acknowledge rendered rows on close")

        tracker.open(origin: .hover, initial: ["input"])
        tracker.visibility("input", visible: true, generation: tracker.generation)
        tick(0); tick(0.5)
        tracker.open(origin: .automatic, initial: ["input"], keepingVisibility: true)
        try require(tracker.close() == ["input"], "Re-reveals keep an earned visit")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-close-ack-\(UUID().uuidString)")
        let suite = "tokenotch-close-ack-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = TokenotchModel(defaults: defaults, root: root)
        model.clock = now
        model.attention.observe(event(.inputRequested, session: "a"), now: now)
        model.attention.observe(event(.approvalRequested, session: "b"), now: now)
        model.attention.observe(event(.failed, session: "c"), now: now)
        model.attention.observe(event(.context, session: "d"), now: now)
        model.attention.observe(event(.compaction, success: false), now: now)
        model.attention.observe(event(.stopped, session: "e"), now: now)
        model.attention.observe(event(.inputRequested, session: "untouched"), now: now)
        let untouched = model.attention.state.notices.first {
            $0.sessionID == model.attention.state.sessionID(source: .cli, hash: ActivityEvent.digest("untouched"))
        }!
        let looked = Set(model.attention.state.notices.map(\.id)).subtracting([untouched.id])
        try require(looked.count == 6, "Every notice kind is represented")
        model.attention.acknowledge(looked, now: now)
        let notices = model.attention.state.notices
        try require(notices.filter { looked.contains($0.id) }.allSatisfy { $0.viewedAt != nil && !$0.needsHighlight },
                    "Visited notices of every kind stop needing attention")
        try require(notices.first { $0.kind == .stopped }?.disposition == .pending,
                    "Stops are marked viewed rather than dismissed")
        try require(notices.filter { looked.contains($0.id) && $0.kind != .stopped }.allSatisfy { $0.disposition == .dismissed },
                    "Other kinds are dismissed")
        try require(notices.first { $0.id == untouched.id }.map { $0.viewedAt == nil && $0.disposition == .pending } == true,
                    "Notices that were not looked at keep their attention")
    }

    static func quickHoverCard() throws {
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw NotchCheckFailure.failed("Quick hover checks require a display")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-quick-hover-\(UUID().uuidString)")
        let suite = "tokenotch-quick-hover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = TokenotchModel(defaults: defaults, root: root)
        model.clock = now
        model.options.displayID = screen.displayIdentifier
        model.options.edge = "right"
        var time = now
        let away = CGPoint(x: -100_000, y: -100_000)
        var pointer = away
        let fleet = NotchFleet(model: model, openSettings: {},
            isFullScreen: { _ in false }, pointerLocation: { pointer }, now: { time })
        let before = Set(app.windows.map(ObjectIdentifier.init))
        defer {
            fleet.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        func card() -> NSWindow? {
            app.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible &&
                    $0.contentView is ShapeHostingView<CopilotSummaryView>
            }
        }
        model.attention.observe(event(.inputRequested, session: "quick-input"), now: now)
        model.attention.observe(event(.failed, session: "quick-error"), now: now)
        fleet.start()
        settle()
        guard let badge = app.windows.first(where: {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 is NotchPanel
        }) else { throw NotchCheckFailure.failed("No hoverable notch") }
        let pill = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: badge.frame.size),
                                        edge: .right, scale: 1, collapsed: true)
        let notch = CGPoint(x: badge.frame.minX + pill.midX, y: badge.frame.maxY - pill.midY)

        func visit(start: Double, length: Double) throws {
            pointer = notch
            time = now.addingTimeInterval(start)
            settle()
            time = now.addingTimeInterval(start + 0.2)
            settle()
            guard let panel = card() else { throw NotchCheckFailure.failed("Hover did not open the card") }
            pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            settle()
            time = now.addingTimeInterval(start + 0.2 + length)
            settle()
            pointer = away
            settle()
            time = now.addingTimeInterval(start + 0.2 + length + 0.3)
            try NotchChecks.waitUntil { card() == nil }
        }

        try visit(start: 0, length: 0.2)
        try require(model.attention.state.notices.allSatisfy { $0.disposition == .pending && $0.needsHighlight },
                    "A pointer swipe shorter than half a second does not acknowledge")
        try visit(start: 5, length: 0.6)
        try require(model.attention.state.notices.allSatisfy { $0.disposition == .dismissed && $0.viewedAt != nil },
                    "A sub-second visit acknowledges requests and errors once the card closes")
        try require(!NotchPresentation(model: model).needsAttention,
                    "A quick visit clears the attention indicator")
    }
}
