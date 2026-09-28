import Foundation

public struct ServiceIncident: Codable, Equatable {
    public let id: String
    public let resolved: Bool
}

public enum HealthParser {
    public static func parse(_ data: Data) throws -> [ServiceIncident] {
        guard data.count <= 262_144,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let components = json["components"] as? [[String: Any]],
              let incidents = json["incidents"] as? [[String: Any]] else { throw TokenotchError.invalidEvent }
        let copilotIDs = Set(components.compactMap { component -> String? in
            guard let name = component["name"] as? String, name.lowercased().contains("copilot") else { return nil }
            return component["id"] as? String
        })
        guard !copilotIDs.isEmpty else { throw TokenotchError.unavailable }
        return incidents.compactMap { incident in
            guard let id = incident["id"] as? String,
                  let status = incident["status"] as? String,
                  let affected = incident["components"] as? [[String: Any]],
                  affected.contains(where: { ($0["id"] as? String).map(copilotIDs.contains) ?? false }) else { return nil }
            return ServiceIncident(id: ActivityEvent.digest(id), resolved: status == "resolved")
        }
    }
}

public struct HealthLedger: Codable {
    private var active: Set<String>?
    public init() {}
    public mutating func observe(_ incidents: [ServiceIncident]) -> [Notice] {
        let current = Set(incidents.filter { !$0.resolved }.map(\.id))
        let resolved = Set(incidents.filter(\.resolved).map(\.id))
        defer {
            // Keep pending incidents until explicit recovery evidence, not feed omission.
            active = (active ?? []).union(current).subtracting(resolved)
        }
        guard let previous = active else { return [] }
        var notices = current.subtracting(previous).map {
            Notice(id: "incident:\($0)", category: .incident, title: "Copilot service incident",
                   body: "GitHub reports an incident affecting Copilot. Open GitHub Status for details.")
        }
        // Disappearance from an unresolved feed is not explicit resolution evidence.
        notices += incidents.filter { $0.resolved && previous.contains($0.id) }.map {
            Notice(id: "recovery:\($0.id)", category: .recovery, title: "Copilot incident resolved",
                   body: "GitHub reports this Copilot incident as resolved.")
        }
        return notices
    }
}
