import TokenotchCore
import SwiftUI

struct ProviderNotchBadge: View {
    let providers: [UsageProvider]
    let reading: CopilotRingReading
    let edge: NotchEdge
    let scale: CGFloat
    let isCollapsed: Bool
    let open: (UsageProvider) -> Void
    var claudeStatusLine: ClaudeStatusLineSnapshot?
    var now = Date()

    private var claudeQuota: ClaudeQuotaWindow? {
        claudeStatusLine?.quotas.first { $0.kind == .fiveHour } ?? claudeStatusLine?.quotas.first
    }
    private var claudeStale: Bool {
        guard let quota = claudeQuota, let snapshot = claudeStatusLine else { return false }
        return quota.isStale(observedAt: snapshot.observedAt, now: now)
    }
    private var claudeLabel: String {
        claudeQuota.map { "\(Int($0.usedPercentage.rounded()))%" } ?? "\u{2014}"
    }

    var body: some View {
        if providers == [.copilot] {
            NotchBadge(reading: reading, edge: edge, scale: scale, isCollapsed: isCollapsed) { open(.copilot) }
        } else {
            GeometryReader { proxy in
                let rect = NotchLayout.badgeRect(in: CGRect(origin: .zero, size: proxy.size),
                    edge: edge, scale: scale, collapsed: isCollapsed, providerCount: providers.count)
                SideNotchShape(edge: edge, curlRadius: NotchLayout.curlRadius * scale,
                    cornerRadius: NotchLayout.cornerRadius * scale)
                    .fill(Palette.surface).frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    let center = NotchLayout.ringCenter(in: proxy.size, edge: edge, scale: scale, index: index)
                    let along = CGFloat(index) + 0.5
                    let collapsed = edge.isVertical
                        ? CGPoint(x: rect.midX, y: rect.minY + rect.height * along / CGFloat(providers.count))
                        : CGPoint(x: rect.minX + rect.width * along / CGFloat(providers.count), y: rect.midY)
                    Button { open(provider) } label: {
                        VStack(spacing: NotchLayout.ringLabelGap) {
                            if provider == .copilot { CopilotRing(reading: reading) }
                            else {
                                ZStack {
                                    Circle().strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)
                                    if let quota = claudeQuota {
                                        Circle().inset(by: NotchLayout.trackStroke / 2)
                                            .trim(from: 0, to: quota.fraction)
                                            .stroke(claudeStale ? Palette.secondary : Palette.usage(quota.fraction),
                                                style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                    }
                                    ClaudeGlyph().fill(Palette.primary)
                                        .frame(width: NotchLayout.glyphSize, height: NotchLayout.glyphSize)
                                }.frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
                            }
                            if !isCollapsed {
                                Text(provider == .copilot ? reading.label : claudeLabel)
                                    .font(Typography.percent).monospacedDigit().foregroundStyle(Palette.primary)
                                    .frame(height: NotchLayout.labelHeight)
                            }
                        }
                        .scaleEffect(isCollapsed ? scale * 0.32 : scale)
                        .frame(width: NotchLayout.ringDiameter * scale,
                               height: (isCollapsed ? NotchLayout.pillHeight : NotchLayout.cellHeight) * scale)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(isCollapsed ? collapsed : CGPoint(x: center.x,
                        y: center.y + (NotchLayout.cellHeight - NotchLayout.ringDiameter) * scale / 2))
                    .accessibilityLabel(provider.title)
                    .accessibilityValue(provider == .copilot ? reading.accessibilityValue :
                        claudeQuota.map { "\($0.title), \(Int($0.usedPercentage.rounded())) percent used\(claudeStale ? ", stale" : ""); activity unavailable" }
                        ?? "Quota not reported; activity unavailable")
                    .accessibilityHint("Show this provider's observed usage")
                }
            }
        }
    }
}
