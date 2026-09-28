import SwiftUI

/// One scale, four steps, derived from the same reference pixels as every other
/// measurement so the card cannot drift away from the notch it hangs off.
///
/// Instances carry the user's notch scale. The card used to be typeset in fixed
/// points while the ring scaled 0.75x-1.5x around it, which left a 1.5x notch
/// pointing at a normal-sized card.
struct Typography {
    let scale: CGFloat

    init(scale: CGFloat = 1) { self.scale = scale }

    static let standard = Typography()
    /// The badge already applies the scale as a transform, so its label is set
    /// at 1x and scaled with everything else around it.
    static var percent: Font { standard.percent }

    private func font(cap: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: Design.fontSize(capPixels: cap) * scale, weight: weight)
    }

    var percent: Font { font(cap: 27, weight: .semibold) }
    var cardTitle: Font { font(cap: 28.5, weight: .semibold) }
    var cardBody: Font { font(cap: 24.7) }
    var cardSecondary: Font { font(cap: 20.9) }
    var cardCaption: Font { font(cap: 18.5) }
    var cardFinePrint: Font { font(cap: 15) }
}
