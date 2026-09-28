import AppKit
import Foundation

@main
enum NotchSmoke {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try ProductionAppChecks.run()
        let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_PATH"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try UsageReportingChecks.savedAndLive(directory: directory)
        try UsageReportingChecks.liveOnly()
        print("PASS: Settings/notch Today reconciliation, persisted cache categories, restart, source filters, reporting day, live cap, pause, errors and deletion.")
        if CommandLine.arguments.contains("--usage") { return }
        if CommandLine.arguments.contains("--context") {
            try ContextNotchChecks.run(directory: directory)
            print("PASS: per-session notch context bars, placement, scaling, source isolation and unavailable/stale states.")
            return
        }
        try OnboardingChecks.lifecycle()
        try OnboardingChecks.eligibilityAndRecovery()
        try OnboardingChecks.failedInstallAndMigration()
        print("PASS: onboarding configuration gates, lifecycle, migration and approval recovery.")
        try OnboardingChecks.render(directory: directory)
        try OnboardingChecks.connectionStates(directory: directory)
        try OnboardingChecks.interaction()
        print("PASS: onboarding rendering, inline installation and navigation.")
        try ConnectionsChecks.readiness()
        try ConnectionsChecks.setup()
        try ConnectionsChecks.render(directory: directory)
        try ConnectionsChecks.configurationStates(directory: directory)
        print("PASS: connection readiness, consent, recovery and Settings rendering.")
        if CommandLine.arguments.contains("--onboarding") { return }
        try ContextNotchChecks.run(directory: directory)
        try NotificationDeliveryChecks.channels()
        try NotificationDeliveryChecks.displays()
        try VSCodeIntegrationChecks.setupRequest()
        try VSCodeIntegrationChecks.modelUsage("gpt-5.6-terra")
        try VSCodeIntegrationChecks.modelUsage("gpt-5.6-sol")
        var receiverResult: Result<Void, Error>?
        let receiverCheck = Task { @MainActor in
            do {
                try await VSCodeIntegrationChecks.receiverErrorRecovery()
                receiverResult = .success(())
            } catch { receiverResult = .failure(error) }
        }
        defer { receiverCheck.cancel() }
        try NotchChecks.waitUntil { receiverResult != nil }
        guard let receiverResult else { throw NotchCheckFailure.failed("Missing receiver recovery result") }
        try receiverResult.get()
        try UsageTimelineNotchChecks.run(directory: directory)
        try NotchChecks.layout()
        try NotchChecks.geometry()
        try NotchChecks.sectionHeadings(directory: directory)
        try NotchChecks.presentation()
        try SessionAttentionChecks.lifecycle()
        try SessionAttentionChecks.requests()
        try SessionAttentionChecks.notificationRouting()
        try SessionAttentionChecks.persistence()
        try SessionAttentionChecks.exposure()
        try SessionAttentionChecks.requestExposure()
        try SessionAttentionChecks.requestDismissal()
        try SessionAttentionChecks.requestCard()
        try SessionAttentionChecks.requestHoverCard()
        try SessionAttentionChecks.requestRowButtons()
        try SessionAttentionChecks.requestScrollVisibility()
        try SessionAttentionChecks.presentation()
        try SessionAttentionChecks.visibleCard()
        try SessionAttentionChecks.closeAcknowledgment()
        try SessionAttentionChecks.quickHoverCard()
        try NotchChecks.interactions()
        try NotchChecks.preferences()
        try NotchChecks.render(directory: directory)
        try NotchChecks.historyRender(directory: directory)
        try NotchChecks.windows()
        try NotchChecks.autoHide()
        try NotchChecks.fullScreenDetection()
        try NotchChecks.fullScreenVisibility()
        print("PASS: inline onboarding navigation and installation, configured-client completion gate, pause/restart/approval recovery, independent consent, welcome and partial-result renders, independent notification sound/banner/card delivery, multi-display alerts and reconnection, guided connections, setup consent/recovery, connection and setup renders, section headings across states/scales, inline request dismissal, three-second continuous visibility, request scrolling/rearming/persistence, input/approval requests, error-episode policy, session notification routing, notice lifecycle/persistence/migration, accessible colors, visible-row acknowledgment, quick-visit close acknowledgment, four-edge renders, focus, full-screen visibility and window cleanup.")
    }
}
