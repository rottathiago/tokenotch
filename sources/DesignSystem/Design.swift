import SwiftUI

// Shared notch measurements retain the MIT attribution in LICENSE.
enum Design {
    static let scale: CGFloat = 44 / 117
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }
    static func fontSize(capPixels: CGFloat) -> CGFloat { px(capPixels) / 0.714 }
}

private struct NotchReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NotchReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // Overrides allow deterministic fixtures without changing the user's system settings.
    var notchReduceMotion: Bool {
        get { self[NotchReduceMotionKey.self] || accessibilityReduceMotion }
        set { self[NotchReduceMotionKey.self] = newValue }
    }
    var notchReduceTransparency: Bool {
        get { self[NotchReduceTransparencyKey.self] || accessibilityReduceTransparency }
        set { self[NotchReduceTransparencyKey.self] = newValue }
    }
}
