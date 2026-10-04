import AppKit
import SwiftUI
import NotchCore

@MainActor
final class SnippetsStore: ObservableObject {
    static let shared = SnippetsStore()
    static let fileName = "snippets-v1.json"
    @Published private(set) var library = CoreSnippetLibrary()
    @Published private(set) var error: String?
    @Published private(set) var editorOpen = false
    @Published private(set) var unreadable = false
    private var url: URL?
    private let onChange: @MainActor () -> Void
    init(directory: URL? = nil, onChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.portableDidChange() }) {
        self.onChange = onChange
        do {
            let root = try directory ?? LocalToolStorage.directory(); url = root.appendingPathComponent(Self.fileName)
            library = try PlusPortableLibraryFile.load(at: url!, limit: CoreSnippetLibrary.maximumBytes, decode: CoreSnippetLibrary.decode) ?? .init()
        } catch { url = nil; unreadable = true; self.error = "Snippets could not be read; the original is retained: \(error.localizedDescription)" }
    }
    func setEditorOpen(_ value: Bool) { editorOpen = value }
    func exportSyncedLibrary() throws -> CoreSnippetLibrary {
        guard !unreadable, let url else { throw SyncFailure.invalid("Unreadable snippet originals are retained; restore or reset with a backup before syncing.") }
        _ = try PlusPortableLibraryFile.load(at: url, limit: CoreSnippetLibrary.maximumBytes, decode: CoreSnippetLibrary.decode)
        return library.syncLibrary()
    }
    func validateSyncedLibrary(_ value: CoreSnippetLibrary) throws {
        _ = try exportSyncedLibrary(); let next = try library.applyingShared(value)
        guard !editorOpen || next == library else { throw SyncFailure.invalid("Close the snippet editor before applying changed shared snippets; your draft is retained.") }
    }
    func applySyncedLibrary(_ value: CoreSnippetLibrary) throws {
        try validateSyncedLibrary(value); try persist(library.applyingShared(value))
    }
    func prepareSyncRollback() -> @MainActor () -> Void {
        let old = library, oldError = error
        return { self.library = old; self.error = oldError }
    }
    @discardableResult func save(_ snippet: CoreSnippet) -> Bool {
        edit {
            if let index = $0.snippets.firstIndex(where: { $0.id == snippet.id }) { $0.snippets[index] = snippet }
            else { $0.snippets.insert(snippet, at: 0) }
        }
    }
    func remove(_ id: UUID) { _ = edit { $0.snippets.removeAll { $0.id == id } } }
    @discardableResult func addFolder(_ name: String) -> Bool { edit { $0.folders.append(.init(name: name.trimmingCharacters(in: .whitespacesAndNewlines))) } }
    func removeFolder(_ id: UUID) { _ = edit { value in value.folders.removeAll { $0.id == id }; for index in value.snippets.indices where value.snippets[index].folderID == id { value.snippets[index].folderID = nil } } }
    func copy(_ snippet: CoreSnippet, to pasteboard: NSPasteboard = .general) {
        guard library.snippets.contains(where: { $0.id == snippet.id }) else { return }
        pasteboard.clearContents(); if !pasteboard.setString(snippet.text, forType: .string) { error = "macOS could not copy this snippet." }
    }
    private func edit(_ mutate: (inout CoreSnippetLibrary) -> Void) -> Bool {
        do { var next = library; mutate(&next); try persist(next); onChange(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func persist(_ value: CoreSnippetLibrary) throws {
        guard !unreadable, let url else { throw SyncFailure.invalid("The unreadable snippet original was retained.") }
        try PlusPortableLibraryFile.save(value.encoded(), at: url, limit: CoreSnippetLibrary.maximumBytes, decode: CoreSnippetLibrary.decode)
        library = value; error = nil
    }
}

@MainActor
struct SnippetsToolView: View {
    @ObservedObject private var store: SnippetsStore
    @State private var query = ""
    @State private var folderID: UUID?
    @State private var folderName = ""
    @State private var editing: CoreSnippet?
    init(store: SnippetsStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search snippets", text: $query).textFieldStyle(.roundedBorder)
                Picker("Folder", selection: $folderID) { Text("All folders").tag(UUID?.none); ForEach(store.library.folders) { Text($0.name).tag(Optional($0.id)) } }.frame(width: 140)
                Button("New") { editing = CoreSnippet(folderID: folderID, title: "", text: "") }
            }
            HStack { TextField("New folder", text: $folderName).textFieldStyle(.roundedBorder); Button("Add Folder") { if store.addFolder(folderName) { folderName = "" } }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let folderID { Button("Remove Folder") { store.removeFolder(folderID); self.folderID = nil } }
            }
            LocalToolError(message: store.error)
            List(store.library.search(query, folderID: folderID)) { snippet in
                HStack {
                    VStack(alignment: .leading) { Text(snippet.title).font(.headline); Text(String(snippet.text.prefix(160))).font(.caption).lineLimit(2); Text(snippet.allowsSync ? "Eligible for optional sync" : "Local only").font(.caption2).foregroundStyle(.secondary) }
                        .onDrag { NSItemProvider(object: snippet.text as NSString) }
                    Spacer(); Button("Copy") { store.copy(snippet) }.buttonStyle(.borderless)
                    Button("Edit") { editing = snippet }.buttonStyle(.borderless)
                    Button { store.remove(snippet.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(snippet.title)")
                }
            }.frame(height: 235)
            Text("Copy or drag plain text into another app. Snippets are local-only by default; passwords, credentials and verification codes must stay local.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).onChange(of: store.library.folders) { _, folders in
            if let folderID, !folders.contains(where: { $0.id == folderID }) { self.folderID = nil }
        }.sheet(item: $editing) { snippet in
            SnippetEditorView(snippet: snippet, folders: store.library.folders, error: store.error) { value in if store.save(value) { editing = nil } } cancel: { editing = nil }
                .onAppear { store.setEditorOpen(true) }.onDisappear { store.setEditorOpen(false) }
        }
    }
}

@MainActor private struct SnippetEditorView: View {
    @State var snippet: CoreSnippet
    let folders: [CoreSnippetFolder]
    let error: String?
    let save: (CoreSnippet) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Snippet").font(.headline)
            TextField("Title", text: $snippet.title).textFieldStyle(.roundedBorder)
            Picker("Folder", selection: $snippet.folderID) { Text("No folder").tag(UUID?.none); ForEach(folders) { Text($0.name).tag(Optional($0.id)) } }
            TextEditor(text: $snippet.text).frame(height: 170)
            Toggle("Allow ordinary text to sync", isOn: $snippet.allowsSync)
            Text("Leave this off for secrets, credentials or verification codes. Enabling app-wide sync shares eligible text as readable JSON.").font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: error)
            HStack { Button("Cancel", action: cancel); Spacer(); Button("Save") { save(snippet) }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 440)
    }
}
