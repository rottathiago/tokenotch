import AppKit
import TokenotchCore
import SwiftUI
import UniformTypeIdentifiers

private final class TelemetryImportSelection: ObservableObject {
    @Published var source = UsageSource.vscodeLocal
    @Published var consent = false
}

struct UsageSourcePicker: View {
    @Binding var selection: UsageSource?
    var compact = false

    var body: some View {
        if compact {
            picker.pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
        } else {
            picker
        }
    }

    private var picker: some View {
        Picker("Source", selection: $selection) {
            Text("All sources").tag(UsageSource?.none)
            Divider()
            ForEach(UsageSource.allCases) { source in Text(source.title).tag(Optional(source)) }
        }
    }
}

struct TelemetryImportView: View {
    @ObservedObject var history: HistoryController
    @StateObject private var state = TelemetryImportSelection()

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("Export source", selection: $state.source) {
                        ForEach([UsageSource.vscodeLocal, .vscodeCopilot]) { source in Text(source.title).tag(source) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(history.importBusy)
                    .onChange(of: state.source) { history.discardImportPreview() }
                    Button("Choose File…") { chooseExport() }.disabled(history.importBusy)
                }
            } label: {
                Text("Import a telemetry export")
                Text("Add VS Code usage that was recorded before Tokenotch was connected.")
            }
            if history.importBusy {
                LabeledContent {
                    Button("Cancel") { history.cancelImport() }
                } label: {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading export…") }
                }
            }
            if let status = history.importStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let preview = history.importPreview {
                let total = preview.events.reduce(Int64(0)) { sum, event in
                    guard let tokens = event.tokens else { return sum }
                    return sum + tokens.input + tokens.output + tokens.cacheInput + tokens.cacheWrite
                }
                LabeledContent("Source", value: preview.source.title)
                if let first = preview.events.map(\.timestamp).min(), let last = preview.events.map(\.timestamp).max() {
                    LabeledContent("Covers", value: "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
                }
                LabeledContent("Records found", value: preview.events.count.formatted())
                LabeledContent("Tokens", value: total.formatted()).monospacedDigit()
                LabeledContent {
                    Button("Import \(history.importNewCalls.formatted()) Calls…") { state.consent = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(history.importBusy || history.importNewCalls == 0)
                } label: {
                    Text("New model calls")
                    Text("Calls already in history are skipped.")
                }
            }
        } header: {
            Text("Import")
        } footer: {
            SettingsFootnote("Only supported telemetry exports can be imported, never chat history.")
        }
        .confirmationDialog("Import this usage?", isPresented: $state.consent, titleVisibility: .visible) {
            Button("Import Usage") { history.commitImport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds the new calls to local daily history, with hourly detail for the latest seven days. Hashed call receipts prevent double counting. This doesn't turn on recording or create timelines.")
        }
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.title = "Choose a recorded telemetry export"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        history.previewImport(url, source: state.source)
    }
}
