import Foundation

enum TimeFormat: String, Codable, CaseIterable, Identifiable {
    case twelveHour
    case twentyFourHour

    var id: String { rawValue }
    var title: String {
        switch self {
        case .twelveHour: return "12-hour (1:00 PM)"
        case .twentyFourHour: return "24-hour (13:00)"
        }
    }

    var hourPattern: String { self == .twelveHour ? "h a" : "HH" }
    var timePattern: String { self == .twelveHour ? "h:mm a" : "HH:mm" }

    func formatter(in zone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        // Respect the explicit clock choice, not the system's hour-cycle override.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = timePattern
        return formatter
    }
}
