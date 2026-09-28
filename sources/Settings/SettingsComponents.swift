import TokenotchCore
import SwiftUI

enum AppVersion {
    static let fallbackShort = TokenotchProduct.version
    static let fallbackBuild = TokenotchProduct.build

    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackShort
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? fallbackBuild
    }
    static var display: String { "Version \(short) (\(build))" }
    static var isDevelopment: Bool {
        Bundle.main.object(forInfoDictionaryKey: "TokenotchDistributionChannel") as? String != "release"
    }
}

extension SettingsTab {
    static let sidebarGroups: [[SettingsTab]] = [
        [.usage, .history, .sessions],
        [.connections, .notifications, .appearance],
        [.privacy, .about]
    ]

    var title: String {
        switch self {
        case .usage: return "Usage"
        case .history: return "History"
        case .sessions: return "Sessions"
        case .connections: return "Connections"
        case .notifications: return "Notifications"
        case .appearance: return "General"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .usage: return "gauge.with.dots.needle.33percent"
        case .history: return "chart.bar.xaxis"
        case .sessions: return "list.bullet.rectangle"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .notifications: return "bell.badge"
        case .appearance: return "gearshape"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    var tileColor: Color {
        switch self {
        case .usage: return SettingsStyle.brand
        case .history: return .blue
        case .sessions: return .teal
        case .connections: return .green
        case .notifications: return .red
        case .appearance: return .gray
        case .privacy: return .indigo
        case .about: return Color(white: 0.22)
        }
    }
}

enum SettingsStyle {
    static let brand = Color(red: 0.42, green: 0.36, blue: 0.95)
    static let good = Color.green
    static let caution = Color.orange
    static let critical = Color.red

    static func usage(_ fraction: Double) -> Color {
        fraction >= Palette.exhaustedThreshold ? critical : fraction >= Palette.watchThreshold ? caution : good
    }
}

enum MetricFormat {
    static func tokens(_ value: Int64) -> String { NotchPresentation.compact(value) }

    static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds >= 1000 {
            return (milliseconds / 1000).formatted(.number.precision(.fractionLength(milliseconds >= 10_000 ? 0 : 1))) + " s"
        }
        return milliseconds.formatted(.number.precision(.fractionLength(0))) + " ms"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        fraction.formatted(.percent.precision(.fractionLength(digits)))
    }

    static func change(_ percentage: Double?) -> String {
        guard let percentage else { return "—" }
        return String(format: "%+.1f%%", percentage)
    }

    static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Sidebar tile: a white glyph on a rounded, colored square, matching System Settings.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    enum Tone { case neutral, good, caution, critical, brand }
    let text: String
    var symbol: String?
    var tone: Tone = .neutral

    private var color: Color {
        switch tone {
        case .neutral: return .secondary
        case .good: return SettingsStyle.good
        case .caution: return SettingsStyle.caution
        case .critical: return SettingsStyle.critical
        case .brand: return SettingsStyle.brand
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct StatRow: View {
    let tiles: [StatTile]
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                if index > 0 { Divider().frame(height: 34) }
                tile
            }
        }
        .padding(.vertical, 4)
    }
}

/// A slim determinate bar. `ProgressView` in grouped forms reads as a loading indicator.
struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient)
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct TableColumnSpec {
    let title: String
    var alignment: HorizontalAlignment = .trailing
    var help: String?
}

/// A compact, form-friendly table. `Table` embeds its own scroll view, which fights the settings form.
struct MetricTable<Row: Identifiable, Cell: View>: View {
    let columns: [TableColumnSpec]
    let rows: [Row]
    @ViewBuilder let cell: (Row, Int) -> Cell

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.title)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .gridColumnAlignment(column.alignment)
                        .help(column.help ?? "")
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { row in
                GridRow {
                    ForEach(columns.indices, id: \.self) { index in
                        cell(row, index)
                    }
                }
                .font(.callout).monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 2)
    }
}

struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            actions().padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Icon + title + one-line description, used for settings that need a short explanation.
struct DescribedRow<Trailing: View>: View {
    let title: String
    let detail: String
    var symbol: String?
    var symbolColor: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.body).foregroundStyle(symbolColor)
                    .frame(width: 22).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

extension DescribedRow where Trailing == EmptyView {
    init(title: String, detail: String, symbol: String? = nil, symbolColor: Color = .secondary) {
        self.init(title: title, detail: detail, symbol: symbol, symbolColor: symbolColor) { EmptyView() }
    }
}

extension Client {
    var shortTitle: String { self == .cli ? "Copilot CLI" : "VS Code" }
    var symbol: String { self == .cli ? "terminal" : "chevron.left.forwardslash.chevron.right" }
    var openTitle: String { self == .cli ? "Open Terminal" : "Open VS Code" }
}

extension SessionSignal {
    /// System colors keep contrast on light and dark window backgrounds; the notch palette assumes black.
    var settingsColor: Color {
        switch self {
        case .error: return .red
        case .input, .approval, .warning: return .orange
        case .stopped: return .purple
        case .working: return .blue
        case .unknown, .idle: return .secondary
        }
    }
}
