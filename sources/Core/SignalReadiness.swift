import Foundation

public enum SignalCapability: Sendable {
    case supported, unverified, unsupported
}

public enum SignalDelivery: String, Sendable {
    case off = "Off"
    case unverified = "Not verified"
    case unsupported = "Not supported"
    case needsSetup = "Setup incomplete"
    case waiting = "Waiting for data"
    case receiving = "Data received"
    case stale = "No recent data"
    case unavailable = "Unavailable"
    case rejected = "Unsupported observations"
}

public struct SignalReadiness: Sendable {
    public let capability: SignalCapability
    public let enabled: Bool
    public let configured: Bool
    public let listening: Bool
    public let observed: Date?
    public let rejectedAt: Date?

    public init(capability: SignalCapability, enabled: Bool = false, configured: Bool = false,
                listening: Bool = false, observed: Date? = nil, rejectedAt: Date? = nil) {
        self.capability = capability; self.enabled = enabled; self.configured = configured
        self.listening = listening; self.observed = observed; self.rejectedAt = rejectedAt
    }

    public func delivery(now: Date) -> SignalDelivery {
        switch capability {
        case .unverified: return .unverified
        case .unsupported: return .unsupported
        case .supported: break
        }
        guard enabled else { return .off }
        if !configured && !(listening && observed != nil) { return .needsSetup }
        guard listening else { return .unavailable }
        if let rejectedAt {
            if let observed {
                if rejectedAt >= observed { return .rejected }
            } else { return .rejected }
        }
        guard let observed else { return .waiting }
        let age = now.timeIntervalSince(observed)
        guard age.isFinite, age >= -30 else { return .unavailable }
        return age <= 300 ? .receiving : .stale
    }
}

public struct SourceSignalReadiness: Sendable {
    public let source: UsageSource
    public let metrics: SignalReadiness
    public let lifecycle: SignalReadiness
    public init(source: UsageSource, metrics: SignalReadiness, lifecycle: SignalReadiness) {
        self.source = source; self.metrics = metrics; self.lifecycle = lifecycle
    }
}
