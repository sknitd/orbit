import AppKit
import SwiftUI
import NotchCore

@MainActor
struct PlusSearchProvider {
    let id: String
    let title: String
    let snapshot: @MainActor () -> [CoreSearchEntry]
    init(id: String, title: String, snapshot: @escaping @MainActor () -> [CoreSearchEntry]) {
        self.id = id; self.title = title; self.snapshot = snapshot
    }
}

@MainActor
final class PlusGlobalSearchStore: ObservableObject {
    static let shared = PlusGlobalSearchStore()
    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var results: [CoreSearchEntry] = []
    @Published var selectedID: String?
    @Published private(set) var message = "Search local tools and content."
    private var providers: [PlusSearchProvider] = []
    private var activation: (@MainActor (CoreSearchEntry) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func configure(providers: [PlusSearchProvider], onActivate: @escaping @MainActor (CoreSearchEntry) -> Void) {
        self.providers = Array(providers.prefix(20)); activation = onActivate
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { refresh() }
    }
    func refresh() {
        task?.cancel(); generation = UUID()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; selectedID = nil; message = "Search local tools and content."; return }
        let id = generation; let query = String(query.prefix(512))
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                // Providers return local snapshots only. No account, database,
                // network, clipboard, or integration grant is requested here.
                var entries: [CoreSearchEntry] = []
                for provider in self.providers where entries.count < 5_000 {
                    entries.append(contentsOf: provider.snapshot().prefix(5_000 - entries.count))
                }
                let snapshot = entries
                let results = await Task.detached(priority: .userInitiated) { CoreGlobalSearch.results(query: query, entries: snapshot) }.value
                try Task.checkCancellation()
                guard self.generation == id else { return }
                self.results = results
                if !results.contains(where: { $0.id == self.selectedID }) { self.selectedID = results.first?.id }
                self.message = self.providers.isEmpty ? "Search sources are not configured yet." : "\(results.count) local results. Use ↑ / ↓ and Return to open."
            } catch is CancellationError { return }
            catch { self.message = error.localizedDescription }
        }
    }
    func moveSelection(_ offset: Int) { selectedID = CoreGlobalSearch.selection(in: results, current: selectedID, offset: offset) }
    func activateSelection() {
        guard let entry = results.first(where: { $0.id == selectedID }) else { return }
        activate(entry)
    }
    func activate(_ entry: CoreSearchEntry) {
        guard results.contains(where: { $0.id == entry.id }) else { return }
        if let file = entry.fileURL, (!file.isFileURL || !FileManager.default.fileExists(atPath: file.path)) {
            message = "This file is unavailable. Refresh results after restoring or removing it."; return
        }
        activation?(entry)
    }
    func stop() { task?.cancel(); task = nil; generation = UUID() }
}

@MainActor
struct GlobalSearchToolView: View {
    @ObservedObject private var store: PlusGlobalSearchStore
    @FocusState private var fieldFocused: Bool
    init(store: PlusGlobalSearchStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global Search").font(.headline)
            TextField("Search tools, notes, tasks, snippets, clipboard and files", text: $store.query)
                .textFieldStyle(.roundedBorder).focused($fieldFocused).onSubmit { store.activateSelection() }
                .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
            ForEach(store.results) { entry in
                Button { store.selectedID = entry.id; store.activate(entry) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).lineLimit(2)
                        Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(store.selectedID == entry.id ? Color.accentColor.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary)
        }.onAppear { fieldFocused = true; if !store.query.isEmpty { store.refresh() } }.onDisappear { store.stop() }
            .background(OrbitNativeToolVisibility(onVisible: { if !store.query.isEmpty { store.refresh() } }, onHidden: { store.stop() }).frame(width: 0, height: 0))
    }
}
