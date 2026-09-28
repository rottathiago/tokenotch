import Foundation

@main
enum TimelineSmoke {
    @MainActor static func main() async throws {
        try HistoryInsightChecks.run()
        try TimelineChecks.persistence()
        try TimelineChecks.ordering()
        try TimelineChecks.limits()
        try TimelineChecks.failures()
        try await TimelineLifecycleChecks.run()
        print("PASS: insight evidence and sample gates; timeline privacy, persistence, deduplication, ordering, exact caps, retention, pagination, consent, pause, removal, deletion and storage recovery.")
    }
}
