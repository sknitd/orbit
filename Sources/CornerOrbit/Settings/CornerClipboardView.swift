import SwiftUI
import CornerCore

@MainActor struct CornerClipboardView: View {
    @ObservedObject private var clipboard: CornerClipboardStore
    init(store: CornerAppStore) { clipboard = store.clipboard }
    init(clipboard: CornerClipboardStore = .shared) { self.clipboard = clipboard }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clipboard Workspace").font(.title2.bold())
            Text("Read and transform explicitly. There is no clipboard watcher, disk history or sync. Input is limited to 1 MB; replacement text and the original Undo backup are limited to 2 MB.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Read Clipboard") { run { try clipboard.read() } }
                Picker("Transform", selection: $clipboard.mode) { ForEach(CornerClipboardMode.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 320)
                Button("Preview") { run { _ = try clipboard.preview() } }.disabled(clipboard.snapshotString == nil)
                Spacer()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Input").font(.headline)
                    TextEditor(text: $clipboard.input).font(.system(.body, design: .monospaced)).frame(height: 210).accessibilityLabel("Clipboard input text")
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                }
                VStack(alignment: .leading) {
                    Text("Preview — clipboard unchanged").font(.headline)
                    ScrollView { Text(clipboard.output.isEmpty ? "The result appears here after Preview." : clipboard.output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(8) }
                        .frame(height: 210).background(Color.secondary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Button("Apply to Clipboard") { run { _ = try clipboard.apply() } }.disabled(clipboard.snapshotString == nil)
                Button("Undo Last Clipboard Change") { run { _ = try clipboard.undo() } }.disabled(!clipboard.canUndo)
                Spacer()
            }
            Text("Apply replaces the clipboard with one plain-text item. Undo restores the original item types and bytes from this session only while no other app has changed the clipboard. Oversized or unreadable originals are refused before replacement.").font(.caption).foregroundStyle(.secondary)
            Text("URL encoding treats input as one query/path value; decoding preserves literal + characters. Base64 decoding requires UTF-8 text. Tracking removal keeps other query values and fragments.").font(.caption).foregroundStyle(.secondary)
            if let error = clipboard.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            Text(clipboard.status).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    private func run(_ operation: () throws -> Void) { do { try operation() } catch { } }
}
