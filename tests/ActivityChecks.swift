import Foundation
#if canImport(TokenotchCore)
import TokenotchCore
#endif

enum ActivityChecks {
    static func run() throws {
        try attention()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func snapshot(_ id: String, _ active: Bool, _ date: Date) throws -> ActivityEvent {
            let data = try JSONSerialization.data(withJSONObject: [
                "sessionId": id, "timestamp": date.timeIntervalSince1970 * 1000, "active": active,
                "prompt": "must-not-survive", "cwd": "/must-not-survive"
            ])
            return try HookNormalizer.normalize(data, source: .cli, hook: "activity", now: date)
        }
        var state = ActivityState()
        let first = try snapshot("one", true, now)
        let second = try snapshot("two", true, now)
        try HistoryChecks.require(first.version == 2 && first.kind == .active, "Versioned live activity")
        try HistoryChecks.require(try state.accept(first, now: now), "Attach during an already-running session")
        try HistoryChecks.require(try state.accept(second, now: now), "Independent concurrent session")
        for offset in stride(from: 30, through: 660, by: 30) {
            let date = now.addingTimeInterval(Double(offset))
            _ = try state.accept(snapshot("one", true, date), now: date)
            _ = try state.accept(snapshot("two", true, date), now: date)
            try HistoryChecks.require(state.sessions.values.filter { $0.isWorking(now: date) }.count == 2,
                                      "Both long-running sessions stay working beyond five minutes")
        }
        let last = now.addingTimeInterval(660)
        try HistoryChecks.require(state.sessions.values.allSatisfy { $0.workStartedAt == now },
                                  "Polling refreshes liveness, not the beginning of work")
        try HistoryChecks.require(state.sessions.values.filter { $0.isWorking(now: last.addingTimeInterval(90)) }.count == 2,
                                  "Snapshot is fresh at exactly 90 seconds")
        try HistoryChecks.require(state.sessions.values.allSatisfy { $0.hasMissingActivity(now: last.addingTimeInterval(91)) },
                                  "Disconnected reporters become unknown, not indefinitely working")
        let idle = try snapshot("two", false, last.addingTimeInterval(1))
        _ = try state.accept(idle, now: idle.timestamp)
        try HistoryChecks.require(state.sessions.values.filter { $0.isWorking(now: idle.timestamp) }.count == 1,
                                  "Idle sessions do not count as working")
        try HistoryChecks.require(state.sessions["cli:\(second.session)"]?.label(now: idle.timestamp) == "Idle (live)",
                                  "Idle is not unavailable or task success")
        try HistoryChecks.require(Notice.activity(first) == nil && Notice.activity(idle) == nil,
                                  "Snapshots never produce task-completion notifications")
        try HistoryChecks.require(try !state.accept(snapshot("two", true, last), now: idle.timestamp),
                                  "Delayed activity cannot undo a newer idle report")
        let stop = ActivityEvent(source: .cli, session: second.session, kind: .stopped, timestamp: idle.timestamp)
        try HistoryChecks.require(try state.accept(stop, now: idle.timestamp), "Same-time lifecycle stop takes precedence")
        try HistoryChecks.require(state.sessions["cli:\(second.session)"]?.label(now: last.addingTimeInterval(400)) == "Execution stopped",
                                  "Known stop does not turn into a missing observation")
        let failed = ActivityEvent(source: .cli, session: second.session, kind: .failed, timestamp: last.addingTimeInterval(2))
        _ = try state.accept(failed, now: failed.timestamp)
        try HistoryChecks.require(try !state.accept(snapshot("two", false, last.addingTimeInterval(3)), now: last.addingTimeInterval(3)),
                                  "Idle snapshots do not erase an explicit error")
        try HistoryChecks.require(try state.accept(snapshot("two", true, last.addingTimeInterval(4)), now: last.addingTimeInterval(4)),
                                  "New work can supersede an old outcome")
        try HistoryChecks.require(state.sessions["cli:\(second.session)"]?.workStartedAt == last.addingTimeInterval(4),
                                  "An actual transition back to work resets the work-start date")
        for invalid in [0, 1, "true", NSNull()] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: [
                "sessionId": "one", "timestamp": now.timeIntervalSince1970 * 1000, "active": invalid
            ])
            try HistoryChecks.rejects("Activity must be a Boolean") {
                _ = try HookNormalizer.normalize(data, source: .cli, hook: "activity", now: now)
            }
        }
        for event in [
            ActivityEvent(source: .vscode, session: first.session, kind: .active, timestamp: now),
            ActivityEvent(source: .cli, session: first.session, kind: .idle, timestamp: now,
                          context: ContextUsage(currentTokens: 1, tokenLimit: 2))
        ] {
            try HistoryChecks.rejects("Reject unsupported snapshot source or content") { try event.validate(now: now) }
        }
        let encoded = try JSONEncoder().encode(first)
        try HistoryChecks.require(!String(decoding: encoded, as: UTF8.self).contains("must-not-survive"),
                                  "Activity snapshots strip all content")
        try HistoryChecks.require(try JSONDecoder().decode(ActivityEvent.self, from: encoded) == first, "Snapshot IPC round trip")
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw HistoryChecks.Failure(description: "Expected an encoded activity object")
        }
        object["version"] = 1
        let legacy = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: object))
        try HistoryChecks.rejects("Snapshots require schema 2") { try legacy.validate(now: now) }

        let root = HistoryChecks.temporaryRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Could not clean activity fixture.\n", stderr) }
        }
        let store = try SessionTimelineStore(root: root, now: now)
        try store.record([first, idle], retention: .seven, now: idle.timestamp)
        try HistoryChecks.require(try store.status().eventCount == 0, "Polling snapshots stay out of saved timelines")
        state.remove(.cli)
        try HistoryChecks.require(state.sessions.isEmpty, "Removing integration clears live snapshots")
    }

    static func attention() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let base: [String: Any] = [
            "sessionId": "private-session", "timestamp": now.timeIntervalSince1970 * 1000,
            "hook_event_name": "Notification", "message": "private-content", "title": "private-content",
            "cwd": "/private-content", "error": ["message": "private-content"]
        ]
        func normalize(_ fields: [String: Any], hook: String = "notification") throws -> ActivityEvent? {
            try HookNormalizer.normalizeObservation(
                JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }),
                source: .cli, hook: hook, now: now)
        }
        var events: [ActivityEvent] = []
        for (type, kind) in [("elicitation_dialog", EventKind.inputRequested), ("permission_prompt", .approvalRequested)] {
            guard let event = try normalize(["notification_type": type]) else {
                throw HistoryChecks.Failure(description: "Expected a request observation")
            }
            events.append(event)
            try HistoryChecks.require(event.kind == kind && event.version == 3 && kind.isAttention,
                                      "Request observations have distinct schema-3 kinds")
        }
        guard let error = try normalize(["recoverable": false], hook: "errorOccurred") else {
            throw HistoryChecks.Failure(description: "Expected an unrecoverable error")
        }
        events.append(error)
        try HistoryChecks.require(error.kind == .unrecoverableError && error.kind != .failed,
                                  "An unrecoverable error is not session termination")
        try HistoryChecks.require(try normalize(["recoverable": true], hook: "errorOccurred") == nil,
                                  "Recoverable errors are valid ignored observations")
        for type in ["shell_completed", "agent_completed", "agent_idle", "future_type"] {
            try HistoryChecks.require(try normalize(["notification_type": type]) == nil,
                                      "Unrelated notifications are ignored without bridge failure")
        }
        for value in [0, 1, "false", NSNull()] as [Any] {
            try HistoryChecks.rejects("Recoverability must be a Boolean") {
                _ = try normalize(["recoverable": value], hook: "errorOccurred")
            }
        }
        for fields in [
            [:], ["notification_type": 1], ["notification_type": ""],
            ["notification_type": "permission_prompt", "sessionId": ""],
            ["notification_type": "permission_prompt", "hook_event_name": "PermissionRequest"],
            ["notification_type": "permission_prompt", "timestamp": true],
            ["notification_type": "agent_idle", "timestamp": (now.timeIntervalSince1970 - 121) * 1000],
            ["notification_type": "permission_prompt", "timestamp": (now.timeIntervalSince1970 + 31) * 1000]
        ] as [[String: Any]] {
            try HistoryChecks.rejects("Malformed or expired attention is not a valid ignore") { _ = try normalize(fields) }
        }
        for boundary in [-120.0, 30.0] {
            try HistoryChecks.require(try normalize(["notification_type": "permission_prompt",
                "timestamp": (now.timeIntervalSince1970 + boundary) * 1000]) != nil, "Ingress bounds are inclusive")
        }
        for event in events {
            let encoded = try JSONEncoder().encode(event)
            let text = String(decoding: encoded, as: UTF8.self)
            try HistoryChecks.require(!text.contains("private-content") && !text.contains("private-session"),
                                      "Request content, raw errors and IDs never survive normalization")
            try HistoryChecks.require(try JSONDecoder().decode(ActivityEvent.self, from: encoded) == event,
                                      "Attention IPC round trip")
            guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw HistoryChecks.Failure(description: "Expected an event object")
            }
            for version in [1, 2, 4] {
                object["version"] = version
                let invalid = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: object))
                try HistoryChecks.rejects("Attention requires schema 3") { try invalid.validate(now: now) }
            }
            try HistoryChecks.rejects("Attention is CLI-only") {
                try ActivityEvent(source: .vscode, session: event.session, kind: event.kind, timestamp: now).validate(now: now)
            }
            try HistoryChecks.rejects("Attention cannot carry metrics") {
                try ActivityEvent(source: .cli, session: event.session, kind: event.kind, timestamp: now,
                                  context: ContextUsage(currentTokens: 1, tokenLimit: 2)).validate(now: now)
            }
            var activity = ActivityState()
            try HistoryChecks.rejects("Requests cannot rewrite working state") { _ = try activity.accept(event, now: now) }
        }
        let installer = HookInstallation()
        let configuration = try JSONSerialization.jsonObject(with: installer.configuration(.cli,
            helper: URL(fileURLWithPath: "/fixture/TokenotchHook"))) as? [String: Any]
        let hooks = configuration?["hooks"] as? [String: [[String: Any]]]
        try HistoryChecks.require(hooks?["notification"]?.first?["matcher"] as? String == "permission_prompt|elicitation_dialog",
                                  "Only actual input/approval notification types are installed")
        try HistoryChecks.require(hooks?["errorOccurred"] != nil && hooks?["permissionRequest"] == nil,
                                  "Capture error reports without intercepting permission decisions")

        let root = HistoryChecks.temporaryRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Could not clean attention fixture.\n", stderr) }
        }
        let timeline = try SessionTimelineStore(root: root, now: now)
        try timeline.record(events, retention: .seven, now: now)
        try HistoryChecks.require(try timeline.status().eventCount == 0, "Attention does not enter saved timelines")
        let history = try UsageHistoryStore(root: root, now: now)
        for event in events {
            try HistoryChecks.rejects("Attention cannot become usage history") { try history.record([event], now: now) }
        }
    }
}
