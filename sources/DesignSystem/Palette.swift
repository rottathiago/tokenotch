import SwiftUI

enum Palette {
    static let surface = Color.black
    static let primary = Color.white
    static let secondary = Color(white: 166 / 255)
    static let ringTrack = Color(white: 48 / 255)
    static let barTrack = Color(white: 45 / 255)
    static let hover = Color(white: 1, opacity: 0.1)
    static let ample = Color(red: 0, green: 1, blue: 136 / 255)
    static let watch = Color(red: 242 / 255, green: 1, blue: 0)
    static let exhausted = Color(red: 1, green: 63 / 255, blue: 0)
    static let sessionWorking = Color(red: 88 / 255, green: 166 / 255, blue: 1)
    static let sessionStopped = Color(red: 188 / 255, green: 140 / 255, blue: 1)
    static let sessionWarning = Color(red: 227 / 255, green: 179 / 255, blue: 65 / 255)
    static let sessionError = Color(red: 1, green: 123 / 255, blue: 114 / 255)

    /// Token categories are identities, not states. These hues stay soft and
    /// clear of the green/yellow/red ramp so a category never reads as a warning.
    static let tokenInput = Color(red: 121 / 255, green: 184 / 255, blue: 1)
    static let tokenOutput = Color(red: 86 / 255, green: 212 / 255, blue: 221 / 255)
    static let tokenCacheRead = Color(red: 190 / 255, green: 160 / 255, blue: 1)
    static let tokenCacheWrite = Color(red: 1, green: 166 / 255, blue: 128 / 255)

    /// The single source of truth for "worth watching" and "nearly gone".
    ///
    /// Red used to wait for a fully spent allowance, so 99% used read as the
    /// same amber as 80%. Both numbers live here and `quotaWarning` reads them,
    /// so the colour and the worded warning cannot disagree.
    static let watchThreshold = 0.75
    static let exhaustedThreshold = 0.9

    static func usage(_ fraction: Double) -> Color {
        fraction >= exhaustedThreshold ? exhausted : fraction >= watchThreshold ? watch : ample
    }

    /// Colour alone cannot carry three states. The ring's arc also changes
    /// texture — solid while there is room, ticked once it is worth watching,
    /// finely ticked once it is nearly gone — so the reading survives a display
    /// that renders the ramp as three near-identical greys.
    static func usageDash(_ fraction: Double) -> [CGFloat] {
        if fraction >= exhaustedThreshold { return [2.5, 2.5] }
        if fraction >= watchThreshold { return [6, 3] }
        return []
    }
}
