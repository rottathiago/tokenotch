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
        let available = ReleaseUpdateController {
            try ReleaseInfo.parse(Data(#"{"tag_name":"v999.0.0","draft":false,"prerelease":false}"#.utf8))
        }
        try NotchChecks.require(!available.checking && available.available == nil, "Update checks started without a user action")
        available.check()
        try NotchChecks.waitUntil { !available.checking }
        try NotchChecks.require(available.available?.tag == "v999.0.0", "A newer stable release was not shown")
        let failed = ReleaseUpdateController { throw ReleaseCheckError.rateLimited }
        failed.check()
        try NotchChecks.waitUntil { !failed.checking }
        try NotchChecks.require(failed.available == nil && failed.message == ReleaseCheckError.rateLimited.rawValue,
                               "Failed update check was reported as success")
        available.stop()
        failed.stop()
        try NotchChecks.require(!FileManager.default.fileExists(atPath: root.path),
                               "UI-only setup checks wrote private app data")
    }
}
