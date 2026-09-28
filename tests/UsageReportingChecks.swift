import AppKit
import Foundation
import TokenotchCore
import SwiftUI
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum UsageReportingChecks {
    private static func event(_ id: String, at date: Date, source: UsageSource = .vscodeLocal,
                              counts: [Int64] = [100, 200, 300_000, 71_800],
                              model: String = "report-model") -> ActivityEvent {
        ActivityEvent(source: source.client, session: ActivityEvent.digest("report-session"),
                      kind: .usage, timestamp: date,
                      tokens: TokenUsage(callID: ActivityEvent.digest(id), input: counts[0], output: counts[1],
                          cacheInput: counts[2], cacheInputReported: true, model: model,
                          durationMs: 1200, timeToFirstTokenMs: 150,
                          cacheWrite: counts[3], cacheWriteReported: true),
                      metricSource: source == .cli ? nil : source)
    }

    private static func deliver(_ events: [ActivityEvent], to model: TokenotchModel) {
        var batch = TelemetryBatch()
        batch.events = events
        model.vscode.onBatch?(batch)
    }

    private static func requireCounts(_ usage: NotchPresentation, counts: [Int64], calls: Int64) throws {
        guard let totals = usage.usageTotals else { throw NotchCheckFailure.failed("Missing Today totals") }
        try NotchChecks.require([totals.input, totals.output, totals.cacheInput, totals.cacheWrite] == counts
            && totals.calls == calls && totals.total == counts.reduce(0, +), "Today lost token categories or calls")
        let rows = usage.allModelRows
        try NotchChecks.require(rows.reduce(0) { $0 + $1.input } == totals.input
            && rows.reduce(0) { $0 + $1.output } == totals.output
            && rows.reduce(0) { $0 + $1.cacheInput } == totals.cacheInput
            && rows.reduce(0) { $0 + $1.cacheWrite } == totals.cacheWrite
            && rows.reduce(0) { $0 + $1.calls } == calls, "Models today disagrees with Today's token categories")
        try NotchChecks.require(totals.cacheReportedCalls == calls && totals.cacheWriteReportedCalls == calls,
                               "Today lost cache reporting coverage")
    }

    static func savedAndLive(directory: URL? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-usage-report-\(UUID().uuidString)")
        let domain = "tokenotch-usage-report-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: "vscodeMetricsEnabled")
        let now = Date()
        let calendar = HistoryCalendar(zone: TimeZone(secondsFromGMT: 14 * 3600)!)
        let start = calendar.calendar.startOfDay(for: now)
        let expected: [Int64] = [60_100, 115_000, 11_700_000, 551_700]
        let remaining: [Int64] = [60_000, 114_800, 11_400_000, 479_900]
        var events = [event("retained-live", at: now)]
        for index in 0..<130 {
            let counts = remaining.map { $0 / 130 + (Int64(index) < $0 % 130 ? 1 : 0) }
            events.append(event("saved-\(index)", at: now,
                                source: index.isMultiple(of: 2) ? .cli : .vscodeCopilot,
                                counts: counts, model: "report-model-\(index % 15)"))
        }
        let previous = event("previous-reporting-day", at: start.addingTimeInterval(-1))
        var store: UsageHistoryStore? = try UsageHistoryStore(root: root, zone: calendar.calendar.timeZone,
                                                            now: calendar.addingDays(-1, to: start))
        try store?.record([previous] + events + events, now: now)
        store = nil
        store = try UsageHistoryStore(root: root, zone: .current, now: now)
        try store?.record([events[0]], now: now)
        let persisted = try store!.query(calendar.interval(.today, selected: now, now: now))
        let hourly = try store!.hourlyTimeline(now: now)
        try NotchChecks.require(persisted.totals.total == 12_426_800 && persisted.totals.calls == 131
            && hourly.total == persisted.totals.total && hourly.calls == 131,
            "Persisted daily/hourly usage changed after deduplication and reopening")
        store = nil

        let model = TokenotchModel(defaults: defaults, root: root)
        let history = model.history
        defer { history.stop() }
        deliver([events[0]], to: model)
        let view = UsageTabView(model: model)
        try NotchChecks.require(view.todayUsage.usageSource == .loading && view.todayUsage.usageTotals == nil,
                               "Settings exposed live counts before reading the archive")
        history.start(available: false)
        try NotchChecks.waitUntil { !history.notchLoading }
        try NotchChecks.require(model.todayTokenTotals?.total == 372_100,
                               "Regression fixture must reproduce the smaller in-memory total")
        try requireCounts(view.todayUsage, counts: expected, calls: 131)
        try NotchChecks.require(view.todayUsage.usageTotals == NotchPresentation(model: model).usageTotals
            && view.todayUsage.usageTotals == persisted.totals,
            "Settings Today, notch Today and stored usage differ")
        try NotchChecks.require(view.todayUsage.provenance.contains("paused")
            && view.todayUsage.savedUsage?.zone == calendar.calendar.timeZone.identifier,
            "Settings hid paused recording or changed the archive's reporting zone")
        let table = ModelUsageTable(models: view.todayUsage.allModelRows)
        try NotchChecks.require(table.models.count == 16 && table.models.reduce(0) { $0 + $1.tokens } == 12_426_800,
                               "Settings model table used the smaller live model list")
        let image = try NotchChecks.hostedImage(view, size: CGSize(width: 820, height: 1050))
        try NotchChecks.save(image, name: "usage-reconciled-today", directory: directory)

        history.selectNotchRange(.week)
        try requireCounts(view.todayUsage, counts: expected, calls: 131)
        try NotchChecks.waitUntil { !history.notchLoading }
        try NotchChecks.require(history.notchUsage?.totals.calls == 132, "Week fixture lost the previous reporting day")
        try requireCounts(view.todayUsage, counts: expected, calls: 131)
        for source in UsageSource.allCases {
            history.selectedSource = source
            try NotchChecks.require(view.todayUsage.usageSource == .loading && view.todayUsage.allModelRows.isEmpty,
                                   "Source change exposed stale Today models or live fallback")
            try NotchChecks.waitUntil { !history.notchLoading }
            let selected = events.filter { $0.usageSource == source }
            let counts = (0..<4).map { index in
                selected.reduce(Int64(0)) { sum, event in
                    let tokens = event.tokens!
                    return sum + [tokens.input, tokens.output, tokens.cacheInput, tokens.cacheWrite][index]
                }
            }
            try requireCounts(view.todayUsage, counts: counts, calls: Int64(selected.count))
        }
        history.selectedSource = nil
        try NotchChecks.waitUntil { !history.notchLoading }
        deliver((0..<4097).map { event("live-cap-\($0)", at: now, counts: [1, 0, 0, 0]) }, to: model)
        try NotchChecks.require(model.tokenSampleLimitReached, "Live cap fixture did not exceed the memory limit")
        try requireCounts(view.todayUsage, counts: expected, calls: 131)
        model.clearLocalHistory()
        try NotchChecks.require(model.todayTokenTotals == nil, "Clear live data retained token samples")
        try requireCounts(view.todayUsage, counts: expected, calls: 131)

        history.tick(now: calendar.addingDays(1, to: now))
        try NotchChecks.require(view.todayUsage.usageSource == .loading, "Midnight retained yesterday's Today total")
        try NotchChecks.waitUntil { !history.notchLoading }
        try requireCounts(view.todayUsage, counts: [0, 0, 0, 0], calls: 0)
        history.tick(now: now)
        try NotchChecks.waitUntil { !history.notchLoading }
        history.selectNotchRange(.today)
        try NotchChecks.waitUntil { !history.notchLoading }
        try requireCounts(view.todayUsage, counts: expected, calls: 131)

        history.setEnabled(true)
        history.setAvailable(true)
        try NotchChecks.waitUntil { history.recording || history.error != nil }
        history.observe(event("new-live-cli", at: Date(), source: .cli, counts: [10, 20, 30, 40]))
        history.tick(now: Date())
        try NotchChecks.waitUntil { history.todayUsage?.totals.calls == 132 }
        try requireCounts(view.todayUsage, counts: zip(expected, [10, 20, 30, 40]).map(+), calls: 132)
        try NotchChecks.require(view.todayUsage.usageTotals == NotchPresentation(model: model).usageTotals,
                               "A committed update did not reach both views")

        let journal = root.appendingPathComponent("history/usage.sqlite-journal")
        let untouched = root.appendingPathComponent("untouched")
        try PrivateFiles.write(Data("fixture".utf8), to: untouched)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: untouched)
        history.tick(now: Date())
        try NotchChecks.waitUntil { history.error != nil }
        try NotchChecks.require(view.todayUsage.usageSource == .unavailable && view.todayUsage.usageTotals == nil
            && view.todayUsage.allModelRows.isEmpty, "Storage failure left success-shaped Settings totals")
        try FileManager.default.removeItem(at: journal)
        history.retry()
        try NotchChecks.waitUntil { history.recording && !history.notchLoading }
        try NotchChecks.require(view.todayUsage.usageTotals?.calls == 132, "Retry lost saved Today usage")
        history.deleteAll()
        try NotchChecks.require(view.todayUsage.usageTotals == nil, "Deletion left stale Settings totals")
        try NotchChecks.waitUntil { history.recording && !history.notchLoading }
        try requireCounts(view.todayUsage, counts: [0, 0, 0, 0], calls: 0)
    }

    static func liveOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenotch-live-report-\(UUID().uuidString)")
        let domain = "tokenotch-live-report-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: "vscodeMetricsEnabled")
        let model = TokenotchModel(defaults: defaults, root: root)
        let history = model.history
        history.start(available: false)
        defer { history.stop() }
        deliver([event("live-only", at: Date())], to: model)
        try NotchChecks.waitUntil { !history.notchLoading }
        let view = UsageTabView(model: model)
        try requireCounts(view.todayUsage, counts: [100, 200, 300_000, 71_800], calls: 1)
        try NotchChecks.require(view.todayUsage.usageTotals == NotchPresentation(model: model).usageTotals
            && view.todayUsage.usageSource == .live && view.todayUsage.provenance.contains("not saved"),
            "Without an archive, Settings and notch must share labeled live-only usage")
        history.selectNotchRange(.week)
        try NotchChecks.waitUntil { !history.notchLoading }
        try NotchChecks.require(NotchPresentation(model: model).usageSource == .needsHistory,
                               "Live observations became saved weekly usage")
        try requireCounts(view.todayUsage, counts: [100, 200, 300_000, 71_800], calls: 1)
        history.setEnabled(true)
        try NotchChecks.waitUntil { !history.notchLoading }
        try requireCounts(view.todayUsage, counts: [0, 0, 0, 0], calls: 0)
        try NotchChecks.require(view.todayUsage.usageSource == .saved && model.todayTokenTotals?.calls == 1,
                               "An empty archive must not be silently replaced or combined with live usage")
    }
}
