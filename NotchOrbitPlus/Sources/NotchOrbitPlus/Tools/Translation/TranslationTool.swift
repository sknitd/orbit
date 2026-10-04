import AppKit
import Combine
import SwiftUI
import NotchCore
#if canImport(Translation)
import Translation
#endif

@MainActor
final class TranslationToolStore: ObservableObject {
    static let shared = TranslationToolStore()
    @Published var input = ""
    @Published var source = "en"
    @Published var target = "es"
    @Published private(set) var output = ""
    @Published private(set) var request: OrbitTranslationRequest?
    @Published private(set) var isWorking = false
    @Published private(set) var status = "Choose languages and Translate. Apple's local models may need a download."
    @Published private(set) var error: String?
    func begin() {
        do {
            guard !isWorking else { return }
            let next = try OrbitTranslationRequest(text: input, source: source, target: target)
            output = ""; error = nil; isWorking = true; request = next
            status = "Preparing Apple's local language models…"
        } catch { self.error = error.localizedDescription }
    }
    func isCurrent(_ id: UUID) -> Bool { request?.id == id && isWorking }
    func prepared(_ id: UUID) { if isCurrent(id) { status = "Translating on this Mac…" } }
    func complete(_ id: UUID, text: String) {
        guard isCurrent(id) else { return }
        guard !text.isEmpty else { fail(id, message: "Apple Translation returned no text."); return }
        output = text; isWorking = false; request = nil; status = "Local translation ready."
    }
    func fail(_ id: UUID, message: String) {
        guard isCurrent(id) else { return }
        isWorking = false; request = nil; error = message; status = "Translation did not finish."
    }
    func cancel() { request = nil; isWorking = false; status = "Translation stopped; late results are ignored." }
    func shutdown() { cancel() }
    func paste(_ board: NSPasteboard = .general) { if let text = board.string(forType: .string) { input = text } }
    func copy(_ board: NSPasteboard = .general) { guard !output.isEmpty else { return }; board.clearContents(); board.setString(output, forType: .string) }
}

@MainActor
struct TranslationToolView: View {
    @ObservedObject var store: TranslationToolStore
    init(store: TranslationToolStore = .shared) { self.store = store }
    var body: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { OrbitNativeTranslationPanel(store: store) }
        else { Text("Local translation requires macOS 15 or later. There is no cloud fallback.").font(.caption).foregroundStyle(.secondary) }
        #else
        Text("This SDK does not provide Apple Translation.").font(.caption).foregroundStyle(.secondary)
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
@MainActor
private struct OrbitNativeTranslationPanel: View {
    @ObservedObject var store: TranslationToolStore
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Translate", systemImage: "character.bubble").font(.headline)
            HStack {
                Picker("From", selection: $store.source) { ForEach(OrbitTranslationLanguage.choices) { Text($0.title).tag($0.id) } }
                Picker("To", selection: $store.target) { ForEach(OrbitTranslationLanguage.choices) { Text($0.title).tag($0.id) } }
            }.disabled(store.isWorking)
            TextEditor(text: $store.input).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel("Text to translate").disabled(store.isWorking)
            HStack {
                Button("Paste Text") { store.paste() }.disabled(store.isWorking)
                Button("Translate Locally") { store.begin() }.disabled(store.isWorking || store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if store.isWorking { ProgressView().controlSize(.small); Button("Cancel") { store.cancel() } }
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            if !store.output.isEmpty {
                ScrollView { Text(store.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 170)
                Button("Copy Translation") { store.copy() }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Translate starts Apple's on-device session. macOS may ask to download a language model; unsupported language pairs show an error. Your text is not sent to a cloud provider.")
                .font(.caption2).foregroundStyle(.secondary)
        }.onChange(of: store.request?.id) { _, _ in
            if let request = store.request {
                configuration = .init(source: Locale.Language(identifier: request.source), target: Locale.Language(identifier: request.target))
                configuration?.invalidate()
            } else { configuration = nil }
        }.translationTask(configuration, action: Self.translationAction(store: store))
            .background(CaptureToolVisibility(onVisible: {}, onHidden: { store.cancel() }).frame(width: 0, height: 0))
    }

    // Creating the action outside the View's MainActor prevents its
    // non-Sendable framework session from acquiring UI actor isolation.
    // Only the Sendable request snapshot and result text cross to the store.
    nonisolated static func translationAction(store: TranslationToolStore) -> @Sendable (TranslationSession) async -> Void {
        { session in
            guard let request = await store.request, await store.isCurrent(request.id) else { return }
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard await store.isCurrent(request.id) else { return }
                await store.prepared(request.id)
                let result = try await session.translate(request.text)
                try Task.checkCancellation()
                await store.complete(request.id, text: result.targetText)
            } catch { await store.fail(request.id, message: error.localizedDescription) }
        }
    }
}
#endif
