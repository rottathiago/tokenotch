import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case copilot, claudeCode
    public var id: String { rawValue }
    public var title: String { self == .copilot ? "GitHub Copilot" : "Claude Code" }
    public var sources: [UsageSource] { UsageSource.allCases.filter { $0.provider == self } }
    public var activeSources: [UsageSource] { UsageSource.activeCases.filter { $0.provider == self } }
}

public enum ClientSurface: String, Codable, Sendable {
    case cli, editor, desktop
}

public enum UsageSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case cli, vscodeLocal, vscodeCopilot
    case claudeCLI
    case claudeDesktop // Retained only for decoding saved observations.

    public var id: String { rawValue }
    public static let copilotCases: [Self] = [.cli, .vscodeLocal, .vscodeCopilot]
    public static let activeCases: [Self] = [.cli, .vscodeLocal, .vscodeCopilot, .claudeCLI]
    public var provider: UsageProvider {
        switch self {
        case .cli, .vscodeLocal, .vscodeCopilot: return .copilot
        case .claudeCLI, .claudeDesktop: return .claudeCode
        }
    }
    public var client: Client {
        switch self {
        case .cli: return .cli
        case .vscodeLocal, .vscodeCopilot: return .vscode
        case .claudeCLI: return .claudeCLI
        case .claudeDesktop: return .claudeDesktop
        }
    }
    public var surface: ClientSurface { client.surface }
    public var title: String {
        switch self {
        case .cli: return "CLI"
        case .vscodeLocal: return "VS Code Local"
        case .vscodeCopilot: return "VS Code Copilot"
        case .claudeCLI: return "Claude Code CLI"
        case .claudeDesktop: return "Claude (retired source)"
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
