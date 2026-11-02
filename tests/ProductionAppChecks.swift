import AppKit
import TokenotchCore
#if !NOTCH_SMOKE
@testable import Tokenotch
#endif

@MainActor
enum ProductionAppChecks {
    static func run() throws {
        let domain = "tokenotch-production-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = TokenotchModel(defaults: defaults, root: root)
        try NotchChecks.require(!model.onboardingComplete && model.setupStep == .welcome, "First run was silently completed")
        model.advanceOnboarding()
        let resumed = TokenotchModel(defaults: defaults, root: root)
        try NotchChecks.require(resumed.setupStep == .connections && !resumed.onboardingComplete, "Setup did not resume")
        model.advanceOnboarding()
        try NotchChecks.require(model.setupStep == .connections, "Setup bypassed its required connection")
        model.pauseOnboarding()
        let completed = TokenotchModel(defaults: defaults, root: root)
        try NotchChecks.require(!completed.onboardingComplete && !completed.options.notifications.enabled
                               && !completed.history.enabled && !completed.timeline.enabled,
                               "Pausing setup completed onboarding or changed privacy consent")
        let options = try JSONEncoder().encode(TokenotchOptions())
        guard var malformed = try JSONSerialization.jsonObject(with: options) as? [String: Any] else {
            throw NotchCheckFailure.failed("Could not encode preference fixture")
        }
        malformed["scale"] = -1
        do {
            _ = try JSONDecoder().decode(TokenotchOptions.self, from: JSONSerialization.data(withJSONObject: malformed))
            throw NotchCheckFailure.failed("Malformed settings were silently accepted")
        } catch is TokenotchError {}
        let available = ReleaseUpdateController(currentVersion: TokenotchProduct.version, defaults: defaults) {
            try ReleaseInfo.parse(Data(#"{"tag_name":"v999.0.0","draft":false,"prerelease":false}"#.utf8))
        }
        try NotchChecks.require(!available.checking && available.available == nil, "Update checks started without a user action")
        available.check()
        try NotchChecks.waitUntil { !available.checking }
        try NotchChecks.require(available.available?.tag == "v999.0.0", "A newer stable release was not shown")
        let failed = ReleaseUpdateController(defaults: defaults) { throw ReleaseCheckError.rateLimited }
        failed.check()
        try NotchChecks.waitUntil { !failed.checking }
        try NotchChecks.require(failed.available == nil && failed.message == ReleaseCheckError.rateLimited.rawValue,
                               "Failed update check was reported as success")
        available.stop()
        failed.stop()
        try NotchChecks.require(!FileManager.default.fileExists(atPath: root.path),
                               "UI-only setup checks wrote private app data")
        try automaticUpdates()
    }

    private static func automaticUpdates() throws {
        let domain = "tokenotch-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var requests = 0
        var notifications: [String] = []
        var tag = "v1.1.0"
        let latest: () async throws -> ReleaseInfo = {
            requests += 1
            return try ReleaseInfo.parse(Data("""
                {"tag_name":"\(tag)","draft":false,"prerelease":false}
                """.utf8))
        }
        let controller = ReleaseUpdateController(currentVersion: "1.0.0", defaults: defaults, latest: latest)
        controller.onAvailable = { notifications.append($0.tag) }
        controller.poll()
        try NotchChecks.require(!controller.automaticChecks && requests == 0,
                               "Background checks require explicit consent")
        controller.setAutomaticChecks(true)
        try NotchChecks.waitUntil { !controller.checking }
        try NotchChecks.require(requests == 1 && notifications == ["v1.1.0"],
                               "Opting in must discover and notify about a newer release")
        let now = Date()
        controller.poll(now: now.addingTimeInterval(86_399))
        try NotchChecks.require(requests == 1 && !controller.checking,
                               "Background checks must observe the daily retry floor")
        controller.poll(now: now.addingTimeInterval(86_401))
        try NotchChecks.waitUntil { !controller.checking }
        try NotchChecks.require(requests == 2 && notifications.count == 1,
                               "Daily checks must not repeat a release notification")

        let restarted = ReleaseUpdateController(currentVersion: "1.0.0", defaults: defaults, latest: latest)
        restarted.onAvailable = { notifications.append($0.tag) }
        restarted.poll(now: now.addingTimeInterval(2 * 86_400 + 2))
        try NotchChecks.waitUntil { !restarted.checking }
        try NotchChecks.require(restarted.automaticChecks && requests == 3 && notifications.count == 1,
                               "Consent, retry floor and notification deduplication must survive restart")
        tag = "v1.2.0"
        restarted.poll(now: now.addingTimeInterval(3 * 86_400 + 3))
        try NotchChecks.waitUntil { !restarted.checking }
        try NotchChecks.require(notifications == ["v1.1.0", "v1.2.0"],
                               "A subsequent stable release must receive its own notification")
        restarted.setAutomaticChecks(false)
        restarted.poll(now: now.addingTimeInterval(5 * 86_400))
        try NotchChecks.require(requests == 4 && !restarted.checking,
                               "Disabling daily checks must stop background requests")
        restarted.check()
        try NotchChecks.waitUntil { !restarted.checking }
        try NotchChecks.require(requests == 5 && restarted.available?.tag == "v1.2.0"
                               && notifications.count == 2,
                               "Manual checks remain available without background consent or duplicate alerts")
        let current = ReleaseUpdateController(currentVersion: "1.2.0", defaults: defaults, latest: latest)
        current.onAvailable = { notifications.append($0.tag) }
        defaults.removeObject(forKey: "lastUpdateCheck.v1")
        current.setAutomaticChecks(true)
        try NotchChecks.waitUntil { !current.checking }
        try NotchChecks.require(current.available == nil && notifications.count == 2,
                               "The installed version must not be offered as an update")

        let failed = ReleaseUpdateController(currentVersion: "1.0.0", defaults: defaults) {
            throw ReleaseCheckError.rateLimited
        }
        defaults.removeObject(forKey: "lastUpdateCheck.v1")
        failed.setAutomaticChecks(true)
        try NotchChecks.waitUntil { !failed.checking }
        failed.poll()
        try NotchChecks.require(!failed.checking && failed.available == nil
                               && failed.message == ReleaseCheckError.rateLimited.rawValue,
                               "Failed daily checks must surface errors and retain the retry floor")

        let cancelled = ReleaseUpdateController(currentVersion: "1.0.0", defaults: defaults) {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try await latest()
        }
        cancelled.onAvailable = { notifications.append($0.tag) }
        defaults.removeObject(forKey: "lastUpdateCheck.v1")
        cancelled.setAutomaticChecks(true)
        cancelled.setAutomaticChecks(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try NotchChecks.require(!cancelled.checking && cancelled.available == nil && notifications.count == 2,
                               "Revoking consent must cancel an in-flight check and suppress its result")
        controller.stop()
        restarted.stop()
        current.stop()
        failed.stop()
        cancelled.stop()
    }
}
