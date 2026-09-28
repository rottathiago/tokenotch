import AppKit

enum NotchLayout {
    static let modelPricingURL = "https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing"
    static let curlRadius = Design.px(103)
    static let cornerRadius = Design.px(78.8)
    static let bezelFillet = Design.px(28)
    static let bodyDepth = Design.px(186)
    static let pillWidth = Design.px(26)
    static let pillHeight = Design.px(210)
    static let ringDiameter = Design.px(117)
    static let trackStroke = Design.px(15.5)
    static let progressStroke = Design.px(8)
    static let glyphSize = Design.px(46)
    static let ringLabelGap = Design.px(26.9)
    static let activityDiameter = Design.px(72)
    static let activityStroke = Design.px(5.5)
    static let padStart = Design.px(69.5)
    static let padEnd = Design.px(50.1)
    // The collapsed pill's fuel gauge. Both ends of the pill reserve the same
    // zone so the gauge stays centred; only the leading one is ever drawn in,
    // by the working dot or the attention mark, which keeps the geometry fixed
    // whether or not there is anything to report.
    static let gaugeThickness = Design.px(7)
    static let gaugeEndZone = Design.px(38)
    static var gaugeLength: CGFloat { pillHeight - 2 * gaugeEndZone }
    static let labelHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 27), weight: .semibold)
        return ceil(font.ascender - font.descender + font.leading)
    }()
    // Card metrics. These were raw points while everything above came from the
    // reference sheet, so the card alone ignored both the drawing's proportions
    // and the user's scale. They are reference pixels now, and each has a
    // scaled reader for the card to lay itself out with.
    static let cardWidth = Design.px(851)
    static let cardCorner = Design.px(49.5)
    static let cardPadding = Design.px(42.5)
    static let tailLength = Design.px(75)
    static let tailHeight = Design.px(87)
    static let tailGap = Design.px(28)
    static let barHeight = Design.px(10.5)
    static let timelineHeight = Design.px(95.7)
    static let timelineInset = Design.px(21.3)
    static let timelineMeridiemInset = Design.px(42.5)
    static let headerGap = Design.px(17)
    static let blockSpacing = Design.px(21.3)
    static let hairline = Design.px(2.5)
    static let footerHeight = Design.px(69)
    /// The usage-provenance fine print pinned beneath the footer.
    static let provenanceHeight = Design.px(28)
    /// The smallest a tappable row in the card is allowed to be.
    static let rowHeight = Design.px(64)

    /// Everything the card spends on itself before any content: padding top and
    /// bottom, the gap and rule above the footer, the footer and the provenance
    /// line beneath it. Shared so the measuring pass and its budget cannot be
    /// computed two different ways.
    static func cardChrome(scale: CGFloat = 1) -> CGFloat {
        (2 * cardPadding + 2 * blockSpacing + hairline + footerHeight + provenanceHeight) * scale
    }

    static var cellHeight: CGFloat { ringDiameter + ringLabelGap + labelHeight }

    static func scale(_ value: Double) -> CGFloat {
        value.isFinite ? min(max(value, 0.75), 1.5) : 1
    }

    static func size(edge: NotchEdge, scale: CGFloat) -> CGSize {
        let length = 2 * curlRadius + padStart + padEnd
            + (edge.isVertical ? cellHeight : ringDiameter)
        let depth = bodyDepth + (edge.isVertical ? 0 : ringLabelGap + labelHeight)
        return CGSize(width: (edge.isVertical ? depth : length) * scale,
                      height: (edge.isVertical ? length : depth) * scale)
    }

    static func badgeRect(in bounds: CGRect, edge: NotchEdge, scale: CGFloat, collapsed: Bool) -> CGRect {
        guard collapsed else { return bounds }
        let depth = pillWidth * scale
        let length = pillHeight * scale
        switch edge {
        case .right:
            return CGRect(x: bounds.maxX - depth, y: bounds.midY - length / 2, width: depth, height: length)
        case .left:
            return CGRect(x: bounds.minX, y: bounds.midY - length / 2, width: depth, height: length)
        case .top:
            return CGRect(x: bounds.midX - length / 2, y: bounds.minY, width: length, height: depth)
        case .bottom:
            return CGRect(x: bounds.midX - length / 2, y: bounds.maxY - depth, width: length, height: depth)
        }
    }

    // SwiftUI coordinates; the percentage is always below the ring, on every edge.
    static func ringCenter(in size: CGSize, edge: NotchEdge, scale: CGFloat) -> CGPoint {
        if edge.isVertical {
            return CGPoint(x: size.width / 2,
                           y: (curlRadius + padStart + ringDiameter / 2) * scale)
        }
        return CGPoint(x: (curlRadius + padStart + ringDiameter / 2) * scale,
                       y: (bodyDepth / 2) * scale)
    }
}
