import TokenotchCore
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var updates: ReleaseUpdateController
    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    TokenotchLogoView(markHeight: 112)
                        .padding(.top, 10)
                    VStack(spacing: 8) {
                        Text("Let Copilot work. Tokenotch keeps watch.")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(.center)
                        Text("Tokenotch lives in your Mac's notch and follows your GitHub Copilot sessions in VS Code and Copilot CLI: the tokens they spend, the models they use, and the moment they need you.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    NotchIllustration()
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                    Text("Agents are fast, but they still stop to ask. Without a signal, you end up hopping between terminals and editors to check whether a session is waiting for approval, stuck on an error, or done. Tokenotch turns that into a glance: hand off a task, move on to the next one, and come back when the notch calls you.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Work in parallel, not on patrol")
            }

            Section("What Tokenotch gives you") {
                DescribedRow(title: "A tap on the shoulder, not a nag",
                             detail: "The notch lights up when a session asks for approval or input, hits an error, or stops. Everything else stays quiet.",
                             symbol: "hand.raised.fill", symbolColor: .orange)
                DescribedRow(title: "Observed usage, model by model",
                             detail: "See the tokens and optional context or timing your connected clients report. Account quota, when available, is separate.",
                             symbol: "gauge.with.dots.needle.33percent", symbolColor: TokenotchSpark.color)
                DescribedRow(title: "Patterns you can act on",
                             detail: "Daily history and session timelines show how your usage shifts across models and days, so you can match the model to the job.",
                             symbol: "chart.xyaxis.line", symbolColor: .teal)
                DescribedRow(title: "Private by design",
                             detail: "Everything stays on this Mac. Prompts, responses, code and file paths are never saved.",
                             symbol: "lock.shield.fill", symbolColor: SettingsStyle.good)
            }

            Section {
                LabeledContent("Owner", value: "Thiago Rotta")
                LabeledContent("Channel", value: AppVersion.isDevelopment ? "Development (not notarized)" : "Direct download")
                LabeledContent("Version") {
                    Text("\(AppVersion.short) (\(AppVersion.build))").textSelection(.enabled)
                }
                LabeledContent("Updates", value: "Manual")
                LabeledContent("Requires", value: "macOS 15 or later")
            } header: {
                Text("Tokenotch")
            } footer: {
                SettingsFootnote("An independent companion, not an official GitHub or Microsoft product. Local observations can be incomplete; Preview features depend on your client version.")
            }
            Section("Updates") {
                Text(updates.message).foregroundStyle(.secondary)
                Button("Check for Updates") { updates.check() }.disabled(updates.checking)
                if updates.available != nil {
                    Button("Open Official Release") { updates.openRelease() }
                }
            }
            Section("Help") {
                Link("Setup, Recovery and Uninstall",
                     destination: URL(string: "https://github.com/\(TokenotchProduct.repository)/blob/HEAD/docs/support.md")!)
                Link("Report an Issue",
                     destination: URL(string: "https://github.com/\(TokenotchProduct.repository)/issues")!)
                Text("Preview your diagnostic report in Privacy before sharing it. Never post credentials or transcripts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Blue accents used in the Tokenotch About page.
private enum TokenotchSpark {
    static let color = Color(red: 0.0, green: 0.38, blue: 1.0)
    static let highlight = Color(red: 0.0, green: 0.75, blue: 1.0)
}

/// A static sketch of the top edge of a display with Tokenotch's notch, showing a session that needs attention.
private struct NotchIllustration: View {
    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [TokenotchSpark.highlight.opacity(0.2), TokenotchSpark.color.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .frame(height: 96)
                .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 2.5)
                    Circle().trim(from: 0, to: 0.62)
                        .stroke(TokenotchSpark.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    CopilotGlyph().fill(.white, style: FillStyle(eoFill: true))
                        .frame(width: 14, height: 14)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Approval needed").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text("Copilot CLI").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 4)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 14)
            .frame(width: 220, height: 46)
            .background(Color.black,
                        in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .accessibilityHidden(true)
    }
}
