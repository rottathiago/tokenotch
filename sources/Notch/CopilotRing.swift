import TokenotchCore
import SwiftUI

struct CopilotRingReading {
    let quota: CopilotQuota?
    let isStale: Bool
    let isWorking: Bool
    var needsAttention = false
    var sessionSignal: SessionSignal = .idle
    var sessionSummary: String?

    var indicator: SessionSignal {
        if sessionSignal == .error { return .error }
        if needsAttention { return .warning }
        if sessionSignal != .idle { return sessionSignal }
        return isWorking ? .working : .idle
    }

    var fraction: Double? {
        guard let quota, !quota.isUnlimitedEntitlement else { return nil }
        return min(max(1 - quota.remainingPercentage / 100, 0), 1)
    }
    var label: String {
        if let fraction { return "\(Int((fraction * 100).rounded()))%" }
        return quota?.isUnlimitedEntitlement == true ? "\u{221E}" : "\u{2014}"
    }
    var accessibilityValue: String {
        let usage: String
        if let fraction { usage = "\(Int((fraction * 100).rounded())) percent used" }
        else { usage = quota?.isUnlimitedEntitlement == true ? "Unlimited entitlement" : "Quota unavailable" }
        return usage + (isStale ? ", stale" : "") + (isWorking ? ", working (last reported)" : "")
            + (needsAttention ? ", attention needed" : "")
            + (sessionSummary.map { ", \($0)" } ?? "")
    }
}

struct CopilotRing: View {
    let reading: CopilotRingReading
    @Environment(\.notchReduceMotion) private var reduceMotion
    @Environment(\.notchReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            ZStack {
                Circle().strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)
                if let fraction = reading.fraction {
                    let dash = reading.isStale ? [] : Palette.usageDash(fraction)
                    Circle().inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: fraction)
                        .stroke(reading.isStale ? Palette.secondary : Palette.usage(fraction),
                                style: StrokeStyle(lineWidth: NotchLayout.progressStroke,
                                                   lineCap: dash.isEmpty ? .round : .butt, dash: dash))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.9),
                                   value: fraction)
                }
                CopilotGlyph().fill(Palette.primary, style: FillStyle(eoFill: true))
                    .frame(width: NotchLayout.glyphSize, height: NotchLayout.glyphSize)
                    .scaleEffect(0.96)
            }
            .opacity(reading.isStale ? (reduceTransparency ? 0.75 : 0.45) : 1)
            if reading.isWorking {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(Palette.sessionWorking,
                                style: StrokeStyle(lineWidth: NotchLayout.activityStroke, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? -90 :
                            context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
                        .frame(width: NotchLayout.activityDiameter, height: NotchLayout.activityDiameter)
                }
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        .overlay(alignment: .topTrailing) {
            if reading.indicator != .idle && reading.indicator != .working {
                Image(systemName: reading.indicator.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(reading.indicator.color).background(Palette.surface, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

struct NotchGauge: View {
    let reading: CopilotRingReading
    let edge: NotchEdge
    let scale: CGFloat

    var body: some View {
        if let fraction = reading.fraction {
            let length = NotchLayout.gaugeLength * scale
            let thickness = NotchLayout.gaugeThickness * scale
            let along = edge.isVertical
            ZStack(alignment: along ? .top : .leading) {
                Capsule().fill(Palette.ringTrack)
                Capsule().fill(reading.isStale ? Palette.secondary : Palette.usage(fraction))
                    .frame(width: along ? thickness : max(thickness, length * fraction),
                           height: along ? max(thickness, length * fraction) : thickness)
            }
            .frame(width: along ? thickness : length, height: along ? length : thickness)
            .opacity(reading.isStale ? 0.6 : 1)
            .accessibilityHidden(true)
        }
    }
}

struct NotchBadge: View {
    let reading: CopilotRingReading
    let edge: NotchEdge
    let scale: CGFloat
    var isCollapsed = false
    let open: () -> Void
    @Environment(\.notchReduceMotion) private var reduceMotion

    /// The centre of the pill's leading end zone, which is the only part of the
    /// gauge's reserved space that carries anything.
    private func lampCenter(in rect: CGRect) -> CGPoint {
        let inset = NotchLayout.gaugeEndZone * scale / 2
        return edge.isVertical ? CGPoint(x: rect.midX, y: rect.minY + inset)
                               : CGPoint(x: rect.minX + inset, y: rect.midY)
    }

    var body: some View {
        GeometryReader { proxy in
            let rect = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: proxy.size),
                                             edge: edge, scale: scale, collapsed: isCollapsed)
            let center = NotchLayout.ringCenter(in: proxy.size, edge: edge, scale: scale)
            let shape = SideNotchShape(edge: edge, curlRadius: NotchLayout.curlRadius * scale,
                                       cornerRadius: NotchLayout.cornerRadius * scale)
            Button(action: open) {
                ZStack(alignment: .topLeading) {
                    shape.fill(Palette.surface)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    if isCollapsed {
                        NotchGauge(reading: reading, edge: edge, scale: scale)
                            .position(x: rect.midX, y: rect.midY)
                        if reading.indicator != .idle {
                            let lamp = lampCenter(in: rect)
                            Image(systemName: reading.indicator == .working ? "circle.fill" : reading.indicator.symbol)
                                .font(.system(size: (reading.indicator == .working ? 4 : 9) * scale, weight: .bold))
                                .foregroundStyle(reading.indicator.color)
                                .position(x: lamp.x, y: lamp.y)
                                .accessibilityHidden(true)
                        }
                    }
                    VStack(spacing: NotchLayout.ringLabelGap) {
                        CopilotRing(reading: reading)
                        Text(reading.label).font(Typography.percent).monospacedDigit()
                            .foregroundStyle(reading.isStale ? Palette.secondary : Palette.primary)
                            .frame(height: NotchLayout.labelHeight)
                    }
                    .scaleEffect(scale)
                    .position(x: center.x,
                              y: center.y + (NotchLayout.cellHeight - NotchLayout.ringDiameter) * scale / 2)
                    .opacity(isCollapsed ? 0 : 1)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(shape.path(in: rect))
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9),
                           value: isCollapsed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("GitHub Copilot / Copilot CLI")
            .accessibilityValue(reading.accessibilityValue)
            .accessibilityHint("Show allowance, activity and usage by model")
        }
        .preferredColorScheme(.dark)
    }
}
