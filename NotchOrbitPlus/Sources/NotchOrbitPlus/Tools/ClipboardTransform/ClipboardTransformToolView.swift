import AppKit
import SwiftUI
import NotchCore

@MainActor
final class ClipboardTransformStore: ObservableObject {
    static let shared = ClipboardTransformStore()
    @Published var input = "" { didSet { generation = UUID(); output = nil; error = nil } }
    @Published var transformation: CoreClipboardTransform = .jsonPretty { didSet { generation = UUID(); output = nil; error = nil } }
    @Published private(set) var output: String?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private var generation = UUID()
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    func load(_ text: String) {
        guard text.utf8.count <= 100_000 else { error = CoreTransformError.tooLarge.localizedDescription; return }
        input = text
    }
    func loadClipboard() {
        let names = (pasteboard.types ?? []).map { $0.rawValue.lowercased() }
        guard !names.contains(where: { $0.contains("concealed") || $0.contains("transient") || $0.contains("password") }),
              !["1password", "onepassword", "lastpass", "keepass", "bitwarden"].contains(where: (pasteboard.string(forType: .init("org.nspasteboard.source"))?.lowercased() ?? "").contains),
              let text = pasteboard.string(forType: .string) else {
            error = "The clipboard has no available public text. Private and transient copies are skipped."; return
        }
        load(text)
    }
    func transform() {
        guard !busy else { return }
        let id = UUID(); generation = id; busy = true; output = nil; error = nil
        let input = input; let transformation = transformation
        Task {
            defer { self.busy = false }
            do {
                let result = try await Task.detached { try transformation.apply(to: input) }.value
                guard self.generation == id else { return }
                self.output = result
            } catch { if self.generation == id { self.error = error.localizedDescription } }
        }
    }
    func copyOutput() {
        guard let output else { return }
        pasteboard.clearContents()
        if !pasteboard.setString(output, forType: .string) { error = "macOS could not copy the transformed text." }
    }
}

@MainActor
struct ClipboardTransformToolView: View {
    @ObservedObject private var store: ClipboardTransformStore
    init(store: ClipboardTransformStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Transform text locally").font(.headline); Spacer(); Button("Load Clipboard", action: store.loadClipboard) }
            TextEditor(text: $store.input).font(.system(.body, design: .monospaced)).frame(height: 90)
                .accessibilityLabel("Text to transform")
            Picker("Transformation", selection: $store.transformation) { ForEach(CoreClipboardTransform.allCases) { Text($0.title).tag($0) } }
            HStack { Button("Transform", action: store.transform).disabled(store.busy); if store.busy { ProgressView().controlSize(.small) } }
            if let output = store.output {
                ScrollView { Text(output).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 100)
                Button("Copy Result", action: store.copyOutput)
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Formatting JSON preserves numeric values and string escapes. Tracking removal removes utm_*, fbclid, gclid, dclid, msclkid, mc_cid, mc_eid and igshid. Input is never uploaded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
