import SwiftUI

struct TooltipShape: Shape {
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    /// The user's notch scale. The tail and the corner radius used to be fixed
    /// points, so a 1.5x pill grew a card with a 1x pointer welded to it.
    var scale: CGFloat = 1

    var tailLength: CGFloat { NotchLayout.tailLength * scale }
    var tailHeight: CGFloat { NotchLayout.tailHeight * scale }
    var cardCorner: CGFloat { NotchLayout.cardCorner * scale }

    func cardRect(in rect: CGRect) -> CGRect {
        switch direction {
        case .leading: return CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailLength, height: rect.height)
        case .trailing: return CGRect(x: rect.minX + tailLength, y: rect.minY,
                                      width: rect.width - tailLength, height: rect.height)
        case .down: return CGRect(x: rect.minX, y: rect.minY + tailLength,
                                  width: rect.width, height: rect.height - tailLength)
        case .up: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailLength)
        }
    }

    func clampedOffset(in rect: CGRect) -> CGFloat {
        let card = cardRect(in: rect)
        let extent = direction == .leading || direction == .trailing ? card.height : card.width
        let limit = max(0, extent / 2 - cardCorner - tailHeight / 2)
        return min(max(tailOffset, -limit), limit)
    }

    func tip(in rect: CGRect) -> CGPoint {
        let offset = clampedOffset(in: rect)
        switch direction {
        case .leading: return CGPoint(x: rect.maxX, y: rect.midY + offset)
        case .trailing: return CGPoint(x: rect.minX, y: rect.midY + offset)
        case .down: return CGPoint(x: rect.midX + offset, y: rect.minY)
        case .up: return CGPoint(x: rect.midX + offset, y: rect.maxY)
        }
    }

    func path(in rect: CGRect) -> Path {
        let card = cardRect(in: rect)
        let tip = tip(in: rect)
        let half = tailHeight / 2
        let length = tailLength
        let a: CGPoint, b: CGPoint, ca: CGPoint, cb: CGPoint, ta: CGPoint, tb: CGPoint
        switch direction {
        case .leading, .trailing:
            let sign: CGFloat = direction == .leading ? 1 : -1
            let base = tip.x - sign * length
            a = CGPoint(x: base, y: tip.y - half)
            b = CGPoint(x: base, y: tip.y + half)
            ca = CGPoint(x: base, y: tip.y - half / 2)
            cb = CGPoint(x: base, y: tip.y + half / 2)
            ta = CGPoint(x: tip.x - sign * length * 0.42, y: tip.y - half * 0.24)
            tb = CGPoint(x: ta.x, y: tip.y + half * 0.24)
        case .down, .up:
            let sign: CGFloat = direction == .down ? -1 : 1
            let base = tip.y - sign * length
            a = CGPoint(x: tip.x - half, y: base)
            b = CGPoint(x: tip.x + half, y: base)
            ca = CGPoint(x: tip.x - half / 2, y: base)
            cb = CGPoint(x: tip.x + half / 2, y: base)
            ta = CGPoint(x: tip.x - half * 0.24, y: tip.y - sign * length * 0.42)
            tb = CGPoint(x: tip.x + half * 0.24, y: ta.y)
        }
        var tail = Path()
        tail.move(to: a)
        tail.addCurve(to: tip, control1: ca, control2: ta)
        tail.addCurve(to: b, control1: tb, control2: cb)
        tail.closeSubpath()
        return RoundedRectangle(cornerRadius: cardCorner)
            .path(in: card).union(tail)
    }
}

struct NotchCardPlacement {
    let frame: CGRect
    let shape: TooltipShape
    let hoverBridge: CGRect
    let scale: CGFloat
    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    var bodyRect: CGRect { shape.cardRect(in: bounds) }

    static func bodyWidth(notch: CGRect, edge: NotchEdge, visibleFrame: CGRect,
                          scale: CGFloat = 1) -> CGFloat {
        let usable = visibleFrame.insetBy(dx: 8, dy: 8)
        let tail = NotchLayout.tailLength * scale
        let gap = NotchLayout.tailGap * scale
        let space: CGFloat
        switch edge {
        case .right: space = notch.minX - usable.minX - gap - tail
        case .left: space = usable.maxX - notch.maxX - gap - tail
        case .top, .bottom: space = usable.width
        }
        return min(NotchLayout.cardWidth * scale, max(80, space),
                   usable.width - (edge.isVertical ? tail : 0))
    }

    init(notch: CGRect, ringCenter: CGPoint, edge: NotchEdge, visibleFrame: CGRect,
         contentHeight: CGFloat, scale: CGFloat = 1) {
        let usable = visibleFrame.insetBy(dx: 8, dy: 8)
        let tail = NotchLayout.tailLength * scale
        let gap = NotchLayout.tailGap * scale
        let width = Self.bodyWidth(notch: notch, edge: edge, visibleFrame: visibleFrame, scale: scale)
        let availableHeight: CGFloat
        switch edge {
        case .top: availableHeight = notch.minY - usable.minY - gap - tail
        case .bottom: availableHeight = usable.maxY - notch.maxY - gap - tail
        case .left, .right: availableHeight = usable.height
        }
        let bodyHeight = min(contentHeight.rounded(.up), max(80, availableHeight),
                             usable.height - (edge.isVertical ? 0 : tail))
        let size = CGSize(width: width + (edge.isVertical ? tail : 0),
                          height: bodyHeight + (edge.isVertical ? 0 : tail))
        var origin: CGPoint
        switch edge {
        case .right: origin = CGPoint(x: notch.minX - gap - size.width, y: ringCenter.y - size.height / 2)
        case .left: origin = CGPoint(x: notch.maxX + gap, y: ringCenter.y - size.height / 2)
        case .top: origin = CGPoint(x: ringCenter.x - size.width / 2, y: notch.minY - gap - size.height)
        case .bottom: origin = CGPoint(x: ringCenter.x - size.width / 2, y: notch.maxY + gap)
        }
        origin.x = min(max(origin.x, usable.minX), usable.maxX - size.width)
        origin.y = min(max(origin.y, usable.minY), usable.maxY - size.height)
        self.scale = scale
        frame = CGRect(origin: origin, size: size)
        shape = TooltipShape(direction: edge.tooltipDirection,
                             tailOffset: edge.isVertical ? frame.midY - ringCenter.y : ringCenter.x - frame.midX,
                             scale: scale)
        let tip = shape.tip(in: CGRect(origin: .zero, size: size))
        let globalTip = CGPoint(x: frame.minX + tip.x, y: frame.maxY - tip.y)
        let anchor: CGPoint
        switch edge {
        case .right: anchor = CGPoint(x: notch.minX, y: ringCenter.y)
        case .left: anchor = CGPoint(x: notch.maxX, y: ringCenter.y)
        case .top: anchor = CGPoint(x: ringCenter.x, y: notch.minY)
        case .bottom: anchor = CGPoint(x: ringCenter.x, y: notch.maxY)
        }
        hoverBridge = CGRect(x: min(anchor.x, globalTip.x), y: min(anchor.y, globalTip.y),
                             width: abs(anchor.x - globalTip.x), height: abs(anchor.y - globalTip.y))
            .insetBy(dx: -6, dy: -6)
    }
}
