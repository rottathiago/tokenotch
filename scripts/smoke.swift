import Darwin
import Foundation
import AppKit
import SwiftUI

private struct SmokeScreen: ScreenDescribing {
    let frameValue: CGRect
    let visibleFrameValue: CGRect
}

// Executable checks for machines with the Command Line Tools but no XCTest framework.
@main
enum Smoke {
    static func rejects(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected invalid input to be rejected")
        } catch {}
    }

    static func developerMetrics() throws {
        try ContextChecks.run()
        try UsageTimelineChecks.run()
        let now = ISO8601DateFormatter().date(from: "2026-09-20T07:01:00Z")!
        func usage(_ session: String, _ call: String, _ model: String?, _ date: Date) -> ActivityEvent {
            ActivityEvent(source: .cli, session: ActivityEvent.digest(session), kind: .usage, timestamp: date,
                tokens: TokenUsage(callID: ActivityEvent.digest("\(session):\(call)"), input: 10, output: 2, model: model))
        }
        func context(_ session: String, _ current: Int64, _ date: Date) -> ActivityEvent {
            ActivityEvent(source: .cli, session: ActivityEvent.digest(session), kind: .context, timestamp: date,
                          context: ContextUsage(currentTokens: current, tokenLimit: 100))
        }
        var ledger = TokenLedger()
        let first = usage("one", "same", "model-a", now.addingTimeInterval(-90))
        try ledger.observe(first, now: now)
        try ledger.observe(first, now: now)
        try ledger.observe(usage("two", "same", "model-b", now), now: now)
        try ledger.observe(usage("one", "other", nil, now), now: now)
        precondition(ledger.totals?.calls == 3 && ledger.totals?.input == 30 && ledger.totals?.output == 6)
        precondition(ledger.byModel.count == 3 && ledger.bySession.count == 2)
        precondition(ledger.byModel.first { $0.model == nil }?.title == "Model unavailable")
        precondition(ledger.bySession.first { $0.id == ActivityEvent.digest("one") }?.tokens?.calls == 2)
        precondition(ledger.byModel.reduce(0) { $0 + $1.tokens.input } == ledger.totals?.input)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        precondition(ledger.today(now: now, calendar: calendar)?.calls == 2)
        precondition(ledger.todayByModel(now: now, calendar: calendar).reduce(0) { $0 + $1.tokens.calls } == 2)
        try ledger.observe(usage("one", "future", nil, now.addingTimeInterval(20)), now: now)
        precondition(ledger.today(now: now, calendar: calendar)?.calls == 2)
        precondition(ledger.todayByModel(now: now, calendar: calendar).reduce(0) { $0 + $1.tokens.input } == 20)
        precondition(ledger.today(now: now.addingTimeInterval(86_400), calendar: calendar) == nil)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        precondition(ledger.today(now: now, calendar: calendar)?.calls == 3)
        var dstLedger = TokenLedger()
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeFallback = ISO8601DateFormatter().date(from: "2026-11-01T05:59:00Z")!
        let afterFallback = ISO8601DateFormatter().date(from: "2026-11-01T06:01:00Z")!
        try dstLedger.observe(usage("dst", "before", nil, beforeFallback), now: beforeFallback)
        try dstLedger.observe(usage("dst", "after", nil, afterFallback), now: afterFallback)
        precondition(dstLedger.today(now: afterFallback, calendar: calendar)?.calls == 2)
        precondition(dstLedger.todayByModel(now: afterFallback, calendar: calendar).first?.tokens.calls == 2)

        let contextEvent = context("three", 80, now)
        try ledger.observe(contextEvent, now: now)
        try ledger.observe(context("three", 20, now.addingTimeInterval(-1)), now: now)
        try ledger.observe(context("three", 30, now), now: now)
        let observed = ledger.bySession.first { $0.id == ActivityEvent.digest("three") }!
        precondition(observed.tokens == nil && observed.context?.usage.fraction == 0.8)
        precondition(observed.context?.isStale(now: now.addingTimeInterval(300)) == false)
        precondition(observed.context?.isStale(now: now.addingTimeInterval(301)) == true)
        precondition(ledger.totals?.calls == 4 && Notice.activity(contextEvent) == nil)
        var activity = ActivityState()
        rejects { _ = try activity.accept(contextEvent, now: now) }
        try ledger.observe(context("three", 10, now.addingTimeInterval(1)), now: now)
        precondition(ledger.bySession.first { $0.id == ActivityEvent.digest("three") }?.context?.usage.currentTokens == 10)

        let base: [String: Any] = ["usageContract": 1, "sessionId": "private-session", "eventId": "call",
                                  "timestamp": now.timeIntervalSince1970 * 1000,
                                  "prompt": "private-content", "cwd": "/private/path"]
        func normalize(_ fields: [String: Any], _ hook: String) throws -> ActivityEvent {
            try HookNormalizer.normalize(JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }),
                                         source: .cli, hook: hook, now: now)
        }
        let normalUsage = try normalize(["inputTokens": 10, "outputTokens": 2, "model": "vendor/model-1.0"], "usage")
        let normalContext = try normalize(["currentTokens": 120, "tokenLimit": 100], "context")
        precondition(normalUsage.tokens?.model == "vendor/model-1.0" && normalContext.context?.fraction == 1.2)
        for event in [normalUsage, normalContext] {
            let data = try JSONEncoder().encode(event)
            precondition(data.count < 4096 && !String(decoding: data, as: UTF8.self).contains("private"))
            let decoded = try JSONDecoder().decode(ActivityEvent.self, from: data)
            precondition(decoded == event)
        }
        for invalid in [true, -1, 1.5, "1", NSNull(), 1_000_000_001] as [Any] {
            rejects { _ = try normalize(["currentTokens": invalid, "tokenLimit": 100], "context") }
            rejects { _ = try normalize(["currentTokens": 1, "tokenLimit": invalid], "context") }
        }
        rejects { _ = try normalize(["currentTokens": 0, "tokenLimit": 0], "context") }
        for invalid in ["", "bad model", "bad\nmodel", String(repeating: "a", count: 129), NSNull(), 12] as [Any] {
            rejects { _ = try normalize(["inputTokens": 1, "outputTokens": 1, "model": invalid], "usage") }
        }
        let zero = try normalize(["inputTokens": 0, "outputTokens": 0], "usage")
        precondition(zero.tokens?.model == nil && zero.tokens?.input == 0)
        for event in [
            ActivityEvent(source: .vscode, session: normalContext.session, kind: .context, timestamp: now, context: normalContext.context),
            ActivityEvent(source: .cli, session: normalContext.session, kind: .stopped, timestamp: now, context: normalContext.context),
            ActivityEvent(source: .cli, session: normalUsage.session, kind: .usage, timestamp: now,
                          tokens: normalUsage.tokens, context: normalContext.context),
            ActivityEvent(source: .cli, session: normalContext.session, kind: .context, timestamp: now),
        ] {
            rejects { try event.validate(now: now) }
        }

        var bounded = TokenLedger()
        for index in 0..<4097 {
            let date = now.addingTimeInterval(Double(index) / 100)
            try bounded.observe(usage("one", "\(index)", nil, date), now: date)
        }
        precondition(bounded.totals?.calls == 4096 && bounded.lastDiscardedAt == now)
        for index in 0..<101 {
            let date = now.addingTimeInterval(Double(index))
            try bounded.observe(context("\(index)", 1, date), now: date)
        }
        precondition(bounded.bySession.filter { $0.context != nil }.count == 100)
        precondition(!bounded.bySession.contains { $0.id == ActivityEvent.digest("0") })
        bounded.expire(now: now.addingTimeInterval(86_500))
        precondition(bounded.totals == nil && bounded.lastDiscardedAt == nil)
        precondition(bounded.bySession.isEmpty && bounded.byModel.isEmpty)
        print("PASS: developer metrics grouping, day/DST boundaries, deduplication, context ordering, privacy, bounds and expiry.")
    }

    static func main() throws {
        try ProductionChecks.versions()
        try ProductionChecks.accountLogin()
        try ProductionChecks.applicationLock()
        try ProductionChecks.protocolGating()
        try ActivityChecks.run()
        print("PASS: CLI attention hook normalization, filtering, schema/privacy/archive boundaries, live activity snapshots and concurrent sessions.")
        try developerMetrics()
        try HistoryChecks.run()
        try CacheInputChecks.run()
        print("PASS: durable usage history, restart deduplication, calendar comparisons, latency/compaction, context warnings and storage failure safety.")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenotch-\(UUID().uuidString.prefix(8))")
        try PrivateFiles.directory(root)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Could not clean isolated Tokenotch smoke fixture.\n", stderr) }
        }
        let now = Date()
        let payload = try JSONSerialization.data(withJSONObject: [
            "sessionId": "synthetic", "timestamp": now.timeIntervalSince1970 * 1000,
            "stopReason": "end_turn", "prompt": "must-not-survive", "cwd": "/must-not-survive"
        ])
        let event = try HookNormalizer.normalize(payload, source: .cli, hook: "agentStop", now: now)
        precondition(event.kind == .stopped)
        let encodedEvent = try JSONEncoder().encode(event)
        precondition(!String(decoding: encodedEvent, as: UTF8.self).contains("must-not-survive"))
        var activity = ActivityState()
        let first = try activity.accept(event, now: now)
        let duplicate = try activity.accept(event, now: now)
        precondition(first && !duplicate)
        let source = try JSONSerialization.data(withJSONObject: [
            "session_id": "synthetic-vscode", "timestamp": ISO8601DateFormatter().string(from: now),
            "hook_event_name": "Stop", "transcript_path": "/must-not-survive"
        ])
        let vscode = try HookNormalizer.normalize(source, source: .vscode, hook: "Stop", now: now)
        precondition(vscode.kind == .stopped)
        let tokenPayload = try JSONSerialization.data(withJSONObject: [
            "sessionId": "fixture", "eventId": "usage-call", "timestamp": now.timeIntervalSince1970 * 1000,
            "usageContract": 1, "inputTokens": 1200, "outputTokens": 45, "model": "fixture-model", "prompt": "must-not-survive"
        ])
        let tokenEvent = try HookNormalizer.normalize(tokenPayload, source: .cli, hook: "usage", now: now)
        let contextPayload = try JSONSerialization.data(withJSONObject: [
            "sessionId": "fixture", "timestamp": now.timeIntervalSince1970 * 1000,
            "currentTokens": 75000, "tokenLimit": 100000, "prompt": "must-not-survive"
        ])
        let contextEvent = try HookNormalizer.normalize(contextPayload, source: .cli, hook: "context", now: now)
        var tokens = TokenLedger()
        try tokens.observe(tokenEvent, now: now)
        try tokens.observe(tokenEvent, now: now)
        precondition(tokens.totals?.input == 1200 && tokens.totals?.output == 45 && tokens.totals?.calls == 1)
        tokens.expire(now: now.addingTimeInterval(86_401))
        precondition(tokens.totals == nil)
        var rpc = RPCFrames()
        let frame = try RPCFrames.encode(id: 1, method: "status.get")
        let partial = try rpc.append(frame.prefix(7))
        precondition(partial.isEmpty)
        let complete = try rpc.append(frame.dropFirst(7) + frame)
        precondition(complete.count == 2)
        rejects { _ = try rpc.append(Data("Content-Length: 99999999\r\n\r\n".utf8)) }

        let runtimeHome = root.appendingPathComponent("runtime")
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/fixture-copilot.py")
        let runtime = CopilotRuntime(executable: fixture, home: runtimeHome)
        try runtime.signIn()
        let snapshot = try runtime.snapshot()
        precondition(snapshot.identity.login == "fixture-user")
        precondition(snapshot.quotas.first?.usedRequests == Decimal(string: "58.5"))
        precondition(snapshot.runtimeVersion == "synthetic-fixture")
        let requested = try String(contentsOf: runtimeHome.appendingPathComponent("fixture-requests.json"), encoding: .utf8)
        precondition(!requested.contains("session."))
        try Data("changed-account".utf8).write(to: runtimeHome.appendingPathComponent("fixture-mode"))
        rejects { _ = try runtime.snapshot() }
        try Data("rate-limit".utf8).write(to: runtimeHome.appendingPathComponent("fixture-mode"))
        do {
            _ = try runtime.snapshot()
            preconditionFailure("Expected rate-limit classification")
        } catch CopilotConnectionError.rateLimited {}
        let disconnected = CopilotRuntime(executable: fixture, home: runtimeHome)
        disconnected.cancel()
        rejects { _ = try disconnected.snapshot() }
        rejects { _ = try HookNormalizer.normalize(Data(repeating: 32, count: 65_537), source: .cli, hook: "agentStop") }
        rejects { _ = try HookNormalizer.normalize(source, source: .vscode, hook: "SessionStart") }
        rejects { _ = try HookNormalizer.normalize(payload, source: .cli, hook: "errorOccurred") }
        let old = ActivityEvent(source: .cli, session: event.session, kind: .working, timestamp: now.addingTimeInterval(-1))
        let acceptedOld = try activity.accept(old, now: now)
        precondition(!acceptedOld)
        precondition(activity.sessions.values.first?.label(now: now.addingTimeInterval(301)) == "Execution stopped")
        activity.remove(.cli)
        activity.expire(now: now)
        precondition(activity.sessions.isEmpty)

        var preferences = NotificationPreferences()
        var ledger = NotificationLedger()
        let notice = Notice.activity(event)!
        precondition(ledger.evaluate(notice, preferences: preferences, now: now) == nil)
        preferences.enabled = true
        ledger = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        precondition(ledger.evaluate(notice, preferences: preferences, now: now) == nil)
        let new = Notice(id: "new", category: .stopped, title: "Synthetic", body: "Synthetic")
        precondition(ledger.evaluate(new, preferences: preferences, now: now)?.desktop == true)
        preferences.sound = true
        preferences.expandNotch = true
        precondition(!preferences.allows(.stopped, now: now, managedMute: true))
        preferences.snoozedUntil = now.addingTimeInterval(60)
        precondition(!preferences.allows(.stopped, now: now))
        precondition(preferences.allows(.stopped, now: now.addingTimeInterval(61)))
        preferences.snoozedUntil = nil
        preferences.quietEnabled = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        for stamp in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-03-08T07:30:00Z"] {
            precondition(preferences.isQuiet(at: iso.date(from: stamp)!, calendar: calendar))
        }
        precondition(!preferences.isQuiet(at: iso.date(from: "2026-11-01T13:00:00Z")!, calendar: calendar))

        let rule = try TargetRule(amount: Decimal(string: "10.5")!)
        var targets = TargetLedger()
        func sample(_ value: Decimal, _ offset: Double) -> CreditObservation {
            CreditObservation(account: "synthetic", cycle: "2026-09", used: value,
                              observedAt: now.addingTimeInterval(offset), fresh: true)
        }
        precondition(targets.evaluate(sample(0, 0), rule: rule) == nil)
        precondition(targets.evaluate(sample(11, 1), rule: rule) == 100)
        precondition(targets.evaluate(sample(1, 2), rule: rule) == nil)
        precondition(targets.evaluate(sample(11, 3), rule: rule) == nil)
        targets = try JSONDecoder().decode(TargetLedger.self, from: JSONEncoder().encode(targets))
        precondition(targets.evaluate(sample(12, 4), rule: rule) == nil)
        rejects { _ = try TargetRule(amount: 0) }
        rejects { _ = try TargetRule(amount: 1, thresholds: [80, 80]) }
        var health = HealthLedger()
        func incidents(_ status: String, present: Bool = true) throws -> [ServiceIncident] {
            let incident: [String: Any] = ["id": "synthetic", "status": status, "components": [["id": "copilot"]]]
            let feed: [String: Any] = ["components": [["id": "copilot", "name": "Copilot"]],
                                       "incidents": present ? [incident] : []]
            return try HealthParser.parse(JSONSerialization.data(withJSONObject: feed))
        }
        let initial = try incidents("investigating", present: false)
        let active = try incidents("investigating")
        let resolved = try incidents("resolved")
        precondition(health.observe(initial).isEmpty)
        precondition(health.observe(active).map(\.category) == [.incident])
        precondition(health.observe(active).isEmpty)
        precondition(health.observe(initial).isEmpty)
        precondition(health.observe(resolved).map(\.category) == [.recovery])
        rejects { _ = try HealthParser.parse(Data("{}".utf8)) }
        let full = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let screen = SmokeScreen(frameValue: full, visibleFrameValue: full.insetBy(dx: 80, dy: 50))
        for edge in NotchEdge.allCases {
            let size = edge.isVertical ? CGSize(width: 56.325, height: 118.125) : CGSize(width: 118.125, height: 56.325)
            for offset: CGFloat in [-10_000, 0, 10_000] {
                let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: edge, alongOffset: offset)
                precondition(full.contains(frame))
                switch edge {
                case .right: precondition(frame.maxX == full.maxX)
                case .left: precondition(frame.minX == full.minX)
                case .top: precondition(frame.maxY == full.maxY)
                case .bottom: precondition(frame.minY == full.minY)
                }
                let shape = SideNotchShape(edge: edge).path(in: CGRect(origin: .zero, size: size))
                precondition(shape.contains(CGPoint(x: size.width / 2, y: size.height / 2)))
            }
        }
        precondition(FullScreenDetector.isFullScreen(screenBounds: full, frontmostPID: 123, windows: [(123, 0, full)]))
        precondition(!FullScreenDetector.isFullScreen(screenBounds: full, frontmostPID: 123, windows: [(456, 0, full)]))

        let installer = HookInstallation(root: root, cliHome: root.appendingPathComponent("copilot"))
        let helper = root.appendingPathComponent("fixture-helper")
        try PrivateFiles.write(Data("synthetic fixture".utf8), to: helper)
        let extensionData = Data("synthetic owned extension".utf8)
        try installer.install(.cli, bundledHelper: helper, usageExtension: extensionData)
        try installer.install(.vscode, bundledHelper: helper)
        let extensionFile = installer.cliHome.appendingPathComponent("extensions/tokenotch-token-usage/extension.mjs")
        let updatedExtension = Data("synthetic updated extension".utf8)
        let current = try installer.isInstalled(.cli, expectedUsageExtension: extensionData)
        let outdated = try installer.isInstalled(.cli, expectedUsageExtension: updatedExtension)
        let existingExtension = try PrivateFiles.read(extensionFile)
        let existingReceipt = try PrivateFiles.read(root.appendingPathComponent("cli-extension.receipt"))
        precondition(current && !outdated && existingExtension == extensionData && existingReceipt == extensionData)
        let vscodeInstalled = try installer.isInstalled(.vscode, expectedUsageExtension: updatedExtension)
        precondition(vscodeInstalled)
        try PrivateFiles.write(updatedExtension, to: extensionFile)
        rejects { _ = try installer.isInstalled(.cli, expectedUsageExtension: updatedExtension) }
        rejects { try installer.install(.cli, bundledHelper: helper, usageExtension: updatedExtension) }
        try PrivateFiles.write(extensionData, to: extensionFile)
        try installer.install(.cli, bundledHelper: helper, usageExtension: updatedExtension)
        let repaired = try installer.isInstalled(.cli, expectedUsageExtension: updatedExtension)
        precondition(repaired)
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        rejects { _ = try PrivateFiles.read(link) }
        rejects { try PrivateFiles.write(Data("bad".utf8), to: link) }
        let sibling = installer.hookURL(.cli).deletingLastPathComponent().appendingPathComponent("other.json")
        try Data("untouched".utf8).write(to: sibling)
        let delivered = DispatchSemaphore(value: 0)
        let bridge = LocalBridge(root: root)
        let activeSnapshot = ActivityEvent(source: .cli, session: event.session, kind: .active, timestamp: Date())
        let idleSnapshot = ActivityEvent(source: .cli, session: event.session, kind: .idle, timestamp: Date())
        let attentionReports = [EventKind.inputRequested, .approvalRequested, .unrecoverableError].map {
            ActivityEvent(source: .cli, session: event.session, kind: $0, timestamp: Date())
        }
        bridge.onEvent = { value in
            precondition(([event, tokenEvent, contextEvent, activeSnapshot, idleSnapshot] + attentionReports).contains(value))
            delivered.signal()
        }
        try bridge.start()
        defer { bridge.stop() }
        rejects { try LocalBridge(root: root).start() }
        try LocalBridge.send(event, root: root)
        precondition(delivered.wait(timeout: .now() + 2) == .success)
        try LocalBridge.send(tokenEvent, root: root)
        precondition(delivered.wait(timeout: .now() + 2) == .success)
        try LocalBridge.send(contextEvent, root: root)
        precondition(delivered.wait(timeout: .now() + 2) == .success)
        for snapshot in [activeSnapshot, idleSnapshot] + attentionReports {
            try LocalBridge.send(snapshot, root: root)
            precondition(delivered.wait(timeout: .now() + 2) == .success)
        }
        let incompatible = DispatchSemaphore(value: 0)
        bridge.onFailure = { error in
            precondition(error == .metricUpgrade)
            incompatible.signal()
        }
        guard var oldEnvelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tokenEvent)) as? [String: Any],
              var oldTokens = oldEnvelope["tokens"] as? [String: Any] else {
            throw TokenotchError.invalidEvent
        }
        oldTokens.removeValue(forKey: "accountingVersion")
        oldEnvelope["tokens"] = oldTokens
        let oldUsage = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: oldEnvelope))
        try LocalBridge.send(oldUsage, root: root)
        precondition(incompatible.wait(timeout: .now() + 2) == .success)
        precondition(delivered.wait(timeout: .now() + 0.05) == .timedOut)
        try LocalBridge.send(activeSnapshot, root: root)
        precondition(delivered.wait(timeout: .now() + 2) == .success)
        try installer.uninstall(.cli)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copilot/extensions/tokenotch-token-usage/extension.mjs").path))
        let siblingData = try Data(contentsOf: sibling)
        precondition(siblingData == Data("untouched".utf8))
        try installer.uninstall(.vscode)
        print("PASS: activity/token normalization, deduplication, RPC framing, browser-login invocation, quota/identity isolation, rate limits, policy/DST, targets, incidents, geometry, owned hooks/extensions, uninstall and local IPC.")
    }
}
