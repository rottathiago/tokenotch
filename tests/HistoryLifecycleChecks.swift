import Foundation
import TokenotchCore
#if !HISTORY_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum HistoryLifecycleChecks {
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw HistoryChecks.Failure(description: "History lifecycle transition did not finish")
    }

    static func run() async throws {
        let root = HistoryChecks.temporaryRoot()
        let domain = "tokenotch-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = HistoryController(defaults: defaults, root: root)
        controller.start(available: true)
        try await wait { controller.revision > 0 }
        try HistoryChecks.require(!FileManager.default.fileExists(atPath: root.path), "Opt-out created archive")
        try HistoryChecks.require(controller.notchSummary == nil, "Opt-out invented a notch history")
        controller.setEnabled(true)
        try await wait { controller.recording || controller.error != nil }
        try HistoryChecks.require(controller.error == nil, "History failed to enable")
        let now = Date()
        let calendar = HistoryCalendar(zone: TimeZone(identifier: controller.zone)!)
        let interval = calendar.interval(.day, selected: now, now: now)
        controller.observe(HistoryChecks.usage("first", at: now))
        let first = try await controller.read(interval, model: nil)
        try HistoryChecks.require(first?.totals.calls == 1, "Consented event not committed")
        try await wait { controller.notchSummary?.today.calls == 1 }
        try await wait { controller.notchUsage?.totals.calls == 1 && !controller.notchLoading }
        try HistoryChecks.require(controller.todayUsage?.totals == controller.notchUsage?.totals,
                                  "Published Today differs from notch Today")
        try HistoryChecks.require(controller.notchTimeline?.granularity == .hour && controller.notchTimeline?.calls == 1,
                                  "Today timeline was not published with saved totals")
        controller.selectNotchRange(.week)
        controller.selectNotchRange(.today)
        controller.selectNotchRange(.week)
        try await wait { controller.notchUsage?.totals.calls == 1 && !controller.notchLoading }
        try HistoryChecks.require(controller.notchRange == .week, "Range selection was reset by a query")
        try HistoryChecks.require(controller.notchTimeline?.granularity == .day && controller.notchTimeline?.buckets.count == 7
                                  && controller.notchTimeline?.calls == 1, "Rapid range changes left an old timeline")
        try HistoryChecks.require(controller.notchUsage?.models.reduce(Int64(0)) { $0 + $1.tokens.calls } == 1,
                                  "Selected period models disagree with totals")
        try await wait { controller.comparison != nil }
        if let comparison = controller.comparison, let insight = comparison.insights.first {
            controller.selectedEvidence = comparison.evidence(for: insight)
        }
        try HistoryChecks.require(controller.selectedEvidence != nil, "No inspectable sparse evidence")
        try HistoryChecks.require(controller.notchSummary?.change == nil, "New history invented a weekly comparison")
        controller.stop()

        let resumed = HistoryController(defaults: defaults, root: root)
        resumed.start(available: true)
        try await wait { resumed.recording || resumed.error != nil }
        let persisted = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(persisted?.totals.calls == 1, "Restart lost history")
        try HistoryChecks.require(persisted?.days.first?.gap == true, "Clean restart concealed a known recording gap")
        try await wait { resumed.notchSummary?.today.calls == 1 }
        try HistoryChecks.require(resumed.notchTimeline?.calls == 1, "Restart lost hourly detail")
        resumed.observe(HistoryChecks.usage("old", at: now))
        let noBackfill = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(noBackfill?.totals.calls == 1, "Pre-resume event backfilled")
        resumed.setEnabled(false)
        resumed.observe(HistoryChecks.usage("paused", at: Date()))
        let paused = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(paused?.totals.calls == 1, "Paused recording accepted event or lost saved data")
        try await wait { resumed.notchSummary?.today.calls == 1 }
        let tomorrow = calendar.addingDays(1, to: now)
        resumed.tick(now: tomorrow)
        try await wait { resumed.notchSummary?.today.calls == 0 && resumed.notchSummary?.recent.calls == 1 }
        try HistoryChecks.require(resumed.notchUsage?.totals.calls == 0, "Today model snapshot failed to roll over")
        try HistoryChecks.require(resumed.todayUsage?.totals.calls == 0, "Settings Today failed to roll over")
        resumed.selectNotchRange(.week)
        try await wait { resumed.notchUsage?.totals.calls == 1 && !resumed.notchLoading }
        resumed.selectNotchRange(.today)
        resumed.tick(now: now)
        try await wait { resumed.notchSummary?.today.calls == 1 }
        resumed.setEnabled(true)
        try await wait { resumed.recording }
        resumed.setAvailable(false)
        resumed.observe(HistoryChecks.usage("removed", at: Date()))
        let removed = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(removed?.totals.calls == 1, "Integration removal erased history or recorded")
        resumed.setAvailable(true)
        try await wait { resumed.recording }
        resumed.observe(HistoryChecks.usage("queued-before-delete", at: Date()))
        resumed.deleteAll()
        try HistoryChecks.require(resumed.todayUsage == nil && resumed.notchUsage == nil && resumed.notchTimeline == nil
                                  && resumed.navigation == nil, "Deleted model/chart/navigation state survived")
        try HistoryChecks.require(resumed.notchSummary == nil, "Deleted notch summary remained visible")
        try HistoryChecks.require(resumed.comparison == nil && resumed.selectedEvidence == nil,
                                  "Deleted insight evidence remained visible")
        try await wait { resumed.recording || resumed.error != nil }
        let deleted = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(deleted?.totals.calls == 0 && resumed.error == nil, "Queued events resurrected deleted history")
        try await wait { resumed.notchSummary?.today.calls == 0 }
        resumed.observe(HistoryChecks.usage("after-delete", at: Date()))
        let fresh = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(fresh?.totals.calls == 1, "Collection did not resume after deletion")
        let journal = root.appendingPathComponent("history/usage.sqlite-journal")
        let unrelated = root.appendingPathComponent("unrelated")
        try PrivateFiles.write(Data("untouched".utf8), to: unrelated)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: unrelated)
        resumed.observe(HistoryChecks.usage("unsafe-storage", at: Date()))
        do {
            _ = try await resumed.read(interval, model: nil)
            throw HistoryChecks.Failure(description: "Unsafe archive was treated as a successful write")
        } catch is TokenotchError {}
        try await wait { resumed.error != nil && !resumed.recording }
        try HistoryChecks.require(resumed.notchSummary == nil, "Storage failure left a success-shaped notch summary")
        try HistoryChecks.require(resumed.notchUsage == nil, "Storage failure left model totals visible")
        try HistoryChecks.require(resumed.todayUsage == nil, "Storage failure left Settings Today visible")
        try HistoryChecks.require(resumed.notchTimeline == nil, "Storage failure left chart visible")
        try FileManager.default.removeItem(at: journal)
        resumed.retry()
        try await wait { resumed.recording || resumed.error != nil }
        let recovered = try await resumed.read(interval, model: nil)
        try HistoryChecks.require(recovered?.totals.calls == 1 && recovered?.days.first?.gap == true,
                                 "Storage failure lost data or concealed the recording gap")
        try HistoryChecks.require(try Data(contentsOf: unrelated) == Data("untouched".utf8), "Unsafe sidecar touched unrelated data")
        resumed.stop()
        try await sourceFiltering()
        try await confirmedImport()
    }

    static func sourceFiltering() async throws {
        let root = HistoryChecks.temporaryRoot()
        let domain = "tokenotch-source-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = HistoryController(defaults: defaults, root: root)
        controller.start(available: true)
        controller.setAvailableSources([.cli, .vscodeLocal])
        controller.setEnabled(true)
        try await wait { controller.recording || controller.error != nil }
        try HistoryChecks.require(controller.error == nil, "Source-aware recording failed")
        func usage(_ id: String) -> ActivityEvent {
            ActivityEvent(source: .vscode, session: ActivityEvent.digest("vscode-session"),
                          kind: .usage, timestamp: Date(),
                          tokens: TokenUsage(callID: ActivityEvent.digest(id), input: 100, output: 10),
                          metricSource: .vscodeLocal)
        }
        let now = Date()
        let interval = HistoryCalendar(zone: TimeZone(identifier: controller.zone)!)
            .interval(.today, selected: now, now: now)
        controller.observe(HistoryChecks.usage("cli", at: now))
        controller.observe(usage("vscode-one"))
        let combined = try await controller.read(interval, model: nil)
        try HistoryChecks.require(combined?.totals.calls == 2, "Combined sources lost observations")
        controller.selectedSource = .vscodeLocal
        let local = try await controller.read(interval, model: nil)
        try HistoryChecks.require(local?.totals.calls == 1 && local?.totals.total == 110, "Source filter mixed CLI data")
        try await wait { controller.notchUsage?.totals.calls == 1 && !controller.notchLoading }
        try HistoryChecks.require(controller.notchTimeline?.calls == 1, "Chart ignored source filter")
        controller.setAvailableSources([.vscodeLocal])
        try await wait { controller.recording || controller.error != nil }
        controller.observe(HistoryChecks.usage("removed-cli", at: Date()))
        controller.observe(usage("vscode-two"))
        let continued = try await controller.read(interval, model: nil)
        try HistoryChecks.require(continued?.totals.calls == 2, "CLI removal stopped VS Code recording")
        controller.selectedSource = nil
        let all = try await controller.read(interval, model: nil)
        try HistoryChecks.require(all?.totals.calls == 3, "Removed source admitted calls or erased saved data")
        controller.stop()
    }

    static func confirmedImport() async throws {
        let root = HistoryChecks.temporaryRoot()
        let domain = "tokenotch-import-controller-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        try PrivateFiles.directory(root)
        let file = root.appendingPathComponent("export.json")
        let now = Date()
        try PrivateFiles.write(TelemetryChecks.fixture(at: now), to: file)
        let controller = HistoryController(defaults: defaults, root: root)
        controller.start(available: false)
        try await wait { controller.revision > 0 }
        controller.previewImport(file, source: .vscodeLocal)
        try await wait { !controller.importBusy }
        try HistoryChecks.require(controller.importPreview != nil && controller.importNewCalls == 1,
                                  "Supported export did not produce a preview")
        try HistoryChecks.require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history").path),
                                  "Preview created persistent history before confirmation")
        controller.commitImport()
        try await wait { !controller.importBusy }
        let interval = HistoryCalendar(zone: TimeZone(identifier: controller.zone)!)
            .interval(.today, selected: now, now: now)
        let imported = try await controller.read(interval, model: nil)
        try HistoryChecks.require(imported?.totals.calls == 1 && imported?.hasImportedData == true,
                                  "Confirmed import failed to retain usage/provenance")
        try HistoryChecks.require(!controller.enabled && !controller.recording,
                                  "Import silently enabled ongoing recording")
        try await wait { controller.todayUsage?.totals.calls == 1 && !controller.notchLoading }
        try HistoryChecks.require(controller.todayUsage?.totals == imported?.totals
                                  && controller.todayUsage?.hasImportedData == true,
                                  "Settings Today lost imported counts or provenance")
        controller.previewImport(file, source: .vscodeLocal)
        try await wait { !controller.importBusy }
        try HistoryChecks.require(controller.importNewCalls == 0, "Repeated preview did not identify duplicates")
        controller.commitImport()
        controller.deleteAll()
        try await wait { controller.status != "Deleting usage history" }
        let empty = try await controller.read(interval, model: nil)
        try HistoryChecks.require(empty == nil || empty?.totals.calls == 0, "Queued import resurrected deleted history")
        try HistoryChecks.require(!controller.importBusy && controller.importPreview == nil,
                                  "Deletion left stale import progress")
        controller.stop()
    }
}
