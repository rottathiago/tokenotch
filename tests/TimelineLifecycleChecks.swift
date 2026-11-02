import Foundation
import TokenotchCore
#if !HISTORY_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum TimelineLifecycleChecks {
    static func run() async throws {
        let root = HistoryChecks.temporaryRoot()
        let domain = "tokenotch-timeline-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionTimelineController(defaults: defaults, root: root)
        controller.start(clients: [.cli, .vscode])
        try await HistoryLifecycleChecks.wait { controller.revision > 0 }
        try HistoryChecks.require(!FileManager.default.fileExists(atPath: root.path), "Opt-out created timeline archive")
        let old = Date().addingTimeInterval(-1)
        controller.setEnabled(true)
        try await HistoryLifecycleChecks.wait { controller.recording || controller.error != nil }
        try HistoryChecks.require(controller.error == nil, "Timeline enable failed")
        controller.observe(TimelineChecks.event(0, date: old))
        controller.observe(TimelineChecks.event(1, date: Date()))
        controller.observe(TimelineChecks.event(2, date: Date(), source: .vscode))
        try await HistoryLifecycleChecks.wait { controller.archive?.eventCount == 2 }
        let session = try requireSession(controller)
        let before = try await controller.readEvents(session: session.id)
        try HistoryChecks.require(before?.events.count == 1, "Pre-consent backfill")
        controller.stop()
        let resumed = SessionTimelineController(defaults: defaults, root: root)
        resumed.start(clients: [.cli, .vscode])
        try await HistoryLifecycleChecks.wait { resumed.recording && resumed.archive?.eventCount == 2 }
        resumed.setAvailable([.vscode])
        try await HistoryLifecycleChecks.wait { resumed.recording }
        resumed.observe(TimelineChecks.event(3, date: Date()))
        resumed.observe(TimelineChecks.event(4, date: Date(), source: .vscode))
        try await HistoryLifecycleChecks.wait { resumed.archive?.eventCount == 3 }
        resumed.setEnabled(false)
        try await HistoryLifecycleChecks.wait { !resumed.recording }
        resumed.observe(TimelineChecks.event(5, date: Date(), source: .vscode))
        let retained = try await resumed.readEvents(session: session.id)
        try HistoryChecks.require(retained?.events.count == 1, "Pause/removal erased saved CLI rows")
        resumed.setEnabled(true)
        try await HistoryLifecycleChecks.wait { resumed.recording }
        resumed.observe(TimelineChecks.event(6, date: Date(), source: .vscode))
        resumed.deleteAll()
        try await HistoryLifecycleChecks.wait { resumed.recording && resumed.archive?.eventCount == 0 }
        resumed.observe(TimelineChecks.event(7, date: Date(), source: .vscode))
        try await HistoryLifecycleChecks.wait { resumed.archive?.eventCount == 1 }
        try HistoryChecks.require(resumed.sessions.first?.id != session.id, "Deletion reused identity")
        let deleted = try await resumed.readEvents(session: session.id)
        try HistoryChecks.require(deleted?.events.isEmpty == true, "Queued deletion resurrected old rows")
        let journal = root.appendingPathComponent("timeline/sessions.sqlite-journal")
        let unrelated = root.appendingPathComponent("untouched")
        try PrivateFiles.write(Data("safe".utf8), to: unrelated)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: unrelated)
        resumed.observe(TimelineChecks.event(8, date: Date(), source: .vscode))
        try await HistoryLifecycleChecks.wait { resumed.error != nil }
        try HistoryChecks.require(!resumed.recording, "Storage error did not pause")
        try FileManager.default.removeItem(at: journal)
        resumed.retry()
        try await HistoryLifecycleChecks.wait { resumed.recording && resumed.error == nil }
        try HistoryChecks.require(try String(contentsOf: unrelated, encoding: .utf8) == "safe", "Unsafe sidecar changed unrelated data")
        resumed.setEnabled(false)
        resumed.tick(now: Date().addingTimeInterval(31 * 86_400))
        try await HistoryLifecycleChecks.wait { resumed.archive?.eventCount == 0 }
        resumed.stop()
        let overloaded = SessionTimelineController(defaults: defaults, root: root)
        overloaded.start(clients: [.cli])
        overloaded.setEnabled(true)
        try await HistoryLifecycleChecks.wait { overloaded.recording }
        for index in 0..<256 {
            overloaded.observe(TimelineChecks.event(index + 1000, date: Date()))
        }
        try HistoryChecks.require(overloaded.error == nil, "Exact 256-admission bound failed")
        overloaded.observe(TimelineChecks.event(9999, date: Date()))
        try HistoryChecks.require(overloaded.error == TimelineError.queueFull.rawValue && !overloaded.recording,
                                  "257th admission failed silently")
        overloaded.stop()
        try await providerRecording()
    }
    static func providerRecording() async throws {
        let root = HistoryChecks.temporaryRoot()
        let domain = "tokenotch-provider-timeline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = SessionTimelineController(defaults: defaults, root: root)
        controller.start(clients: [.cli])
        controller.setEnabled(true)
        try await HistoryLifecycleChecks.wait { controller.recording || controller.error != nil }
        let first = Date()
        controller.observe(TimelineChecks.event(100, date: first))
        controller.setAvailable([.cli, .claudeCLI])
        controller.setEnabled(true, provider: .claudeCode)
        controller.observe(TimelineChecks.event(101, date: first))
        try await HistoryLifecycleChecks.wait { controller.recordingProviders == [.copilot, .claudeCode] }
        func claude(_ id: String, at date: Date) -> ActivityEvent {
            ActivityEvent(source: .claudeCLI, session: ActivityEvent.digest("claude-synthetic"),
                kind: .usage, timestamp: date,
                tokens: TokenUsage(callID: ActivityEvent.digest(id), input: 1, output: 2,
                                   cacheInputReported: false, cacheWriteReported: false),
                metricSource: .claudeCLI, metricSessionReported: true)
        }
        controller.observe(claude("pre-consent", at: first))
        controller.observe(claude("consented", at: Date()))
        let copilot = try await controller.readStatus(provider: .copilot)
        let claudeStatus = try await controller.readStatus(provider: .claudeCode)
        try HistoryChecks.require(copilot?.eventCount == 2 && copilot?.interrupted == false &&
                                 claudeStatus?.eventCount == 1 && claudeStatus?.interrupted == false,
                                 "Enabling Claude reset a retained timeline window or marked Copilot interrupted")
        let pause = Date()
        controller.setEnabled(false, provider: .claudeCode)
        controller.observe(TimelineChecks.event(102, date: pause))
        controller.observe(claude("paused", at: Date()))
        let retained = try await controller.readStatus(provider: .copilot)
        let paused = try await controller.readStatus(provider: .claudeCode)
        try HistoryChecks.require(retained?.eventCount == 3 && retained?.interrupted == false &&
                                 paused?.eventCount == 1 && paused?.interrupted == true && controller.recording,
                                 "Claude timeline pause affected Copilot or retained a paused observation")
        controller.setEnabled(true, provider: .claudeCode)
        try await HistoryLifecycleChecks.wait { controller.recordingProviders.contains(.claudeCode) }
        controller.observe(claude("pause-backfill", at: pause))
        controller.observe(claude("resumed", at: Date()))
        let resumed = try await controller.readStatus(provider: .claudeCode)
        try HistoryChecks.require(resumed?.eventCount == 2, "Timeline resume backfilled a paused observation")
        controller.stop()
    }
    private static func requireSession(_ controller: SessionTimelineController) throws -> TimelineSession {
        guard let session = controller.sessions.first(where: { $0.source == .cli }) else {
            throw HistoryChecks.Failure(description: "Missing CLI session")
        }
        return session
    }
}
