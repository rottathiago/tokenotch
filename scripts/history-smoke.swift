import Foundation

@main
enum HistorySmoke {
    @MainActor static func main() async throws {
        try HistoryChecks.notchSummary()
        try await HistoryLifecycleChecks.run()
        print("PASS: notch weekly comparisons, DST/midnight, missing samples, gaps, opt-out, consent, persistence, restart, pause, integration removal, queued deletion and resumed recording.")
    }
}
