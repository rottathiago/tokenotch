import Foundation
import TokenotchCore

enum OnboardingStep: String, CaseIterable {
    case welcome, connections, preferences, complete

    var number: Int {
        switch self {
        case .welcome: return 1
        case .connections: return 2
        case .preferences: return 3
        case .complete: return 4
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome to Tokenotch"
        case .connections: return "Connect your clients"
        case .preferences: return "Your preferences"
        case .complete: return "You're ready"
        }
    }
}

struct OnboardingProgress {
    var step: OnboardingStep
    var clients: Set<Client>
    var activeClient: Client?

    init(defaults: UserDefaults) {
        if let value = defaults.string(forKey: "onboardingStep.v2"),
           let saved = OnboardingStep(rawValue: value) {
            step = saved == .complete && !defaults.bool(forKey: "onboardingComplete.v1") ? .connections : saved
        } else {
            switch defaults.integer(forKey: "onboardingStep.v1") {
            case 1: step = .connections
            case 2...: step = .preferences
            default: step = .welcome
            }
        }
        clients = Set((defaults.stringArray(forKey: "onboardingClients.v2") ?? []).compactMap(Client.init(rawValue:)))
        activeClient = defaults.string(forKey: "onboardingActiveClient.v2").flatMap(Client.init(rawValue:))
        if let activeClient { clients.insert(activeClient) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(step.rawValue, forKey: "onboardingStep.v2")
        defaults.set(clients.map(\.rawValue).sorted(), forKey: "onboardingClients.v2")
        defaults.set(activeClient?.rawValue, forKey: "onboardingActiveClient.v2")
    }
}
