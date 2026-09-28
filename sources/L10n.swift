import Foundation

enum L10n {
    static func t(_ key: String.LocalizationValue) -> String { String(localized: key) }
}
