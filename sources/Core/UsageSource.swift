import Foundation

public enum UsageSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case cli, vscodeLocal, vscodeCopilot

    public var id: String { rawValue }
    public var client: Client { self == .cli ? .cli : .vscode }
    public var title: String {
        switch self {
        case .cli: return "CLI"
        case .vscodeLocal: return "VS Code Local"
        case .vscodeCopilot: return "VS Code Copilot"
        }
    }
}

public enum TelemetryError: String, Error, LocalizedError {
    case invalid = "Unsupported telemetry fields. Some usage could not be recorded."
    case unsupported = "This telemetry source or export format is not supported."
    case unavailable = "The local telemetry receiver is unavailable. Check Connections."
    case capacity = "Telemetry exceeded the local processing limit. Usage coverage is partial."
    case unauthorized = "Telemetry authentication failed. Reconfigure the VS Code integration."
    case setup = "VS Code setup could not finish. Check the companion extension and try again."
    case changed = "The selected export changed. Preview it again before importing."
    case cancelled = "Import cancelled. Previously committed observations are retained."
    public var errorDescription: String? { rawValue }
}
