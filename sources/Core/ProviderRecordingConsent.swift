import Foundation

public enum RecordingKind: String, Sendable {
    case usageHistory = "usageHistoryEnabled"
    case sessionTimeline = "sessionTimelineEnabled"
}

public enum ProviderRecordingConsent {
    private static func key(_ kind: RecordingKind, provider: UsageProvider) -> String {
        "\(kind.rawValue):\(provider.rawValue)"
    }

    public static func migrateCopilot(in defaults: UserDefaults) {
        for kind in [RecordingKind.usageHistory, .sessionTimeline] {
            let scoped = key(kind, provider: .copilot)
            if defaults.object(forKey: scoped) == nil {
                defaults.set(defaults.bool(forKey: kind.rawValue), forKey: scoped)
            }
        }
    }

    public static func enabled(_ kind: RecordingKind, provider: UsageProvider, in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key(kind, provider: provider))
    }

    public static func setEnabled(_ value: Bool, kind: RecordingKind,
                                  provider: UsageProvider, in defaults: UserDefaults) {
        defaults.set(value, forKey: key(kind, provider: provider))
        if provider == .copilot { defaults.set(value, forKey: kind.rawValue) }
    }
}
