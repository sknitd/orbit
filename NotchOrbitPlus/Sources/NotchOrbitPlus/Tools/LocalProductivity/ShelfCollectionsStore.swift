import AppKit
import SwiftUI
import NotchCore

struct ShelfLocalConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var library = CoreShelfConfiguration()
    var selectedShelfID = CoreShelfCollection.inboxID
    var enabledRuleIDs: Set<UUID> = []
    var folderBookmarks: [String: Data] = [:]
    func validate() throws {
        try library.validate()
        guard schemaVersion == 1, library.shelves.contains(where: { $0.id == selectedShelfID }),
              enabledRuleIDs.isSubset(of: Set(library.rules.map(\.id))), folderBookmarks.count <= 40,
              folderBookmarks.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.count <= 65_536 }) else {
            throw SyncFailure.invalid("Invalid local shelf configuration; originals were retained.")
        }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 3 * 1024 * 1024 else { throw SyncFailure.invalid("Local shelf configuration exceeds 3 MB.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}

struct ShelfRulePreview: Identifiable {
    let id = UUID()
    let rule: CoreShelfRule
    let lines: [String]
    let fileURLs: [URL]
    let cleanupIDs: [UUID]
    let createdAt = Date()
}

@MainActor final class ShelfCollectionsStore: ObservableObject {
    static let fileName = "file-shelf-layout-v1.json"
    @Published private(set) var state = ShelfLocalConfiguration()
    @Published private(set) var error: String?
    @Published private(set) var watching = false
    @Published var preview: ShelfRulePreview?
    @Published private(set) var editorOpen = false
    var onWatchedFiles: (@MainActor ([URL], CoreShelfRule) -> Void)?
    private var url: URL?
    private let persistState: Bool
    private let onChange: @MainActor () -> Void
    private var watcher: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var watchedFolders: [UUID: URL] = [:]
    private var grantedFolders: Set<UUID> = []
    private var seen: [UUID: Set<URL>] = [:]
    private var generation = UUID()
    init(directory: URL, persistState: Bool = true, onChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.portableDidChange() }) {
        self.persistState = persistState; self.onChange = onChange
        url = directory.appendingPathComponent(Self.fileName)
        if persistState { do { state = try PlusPortableLibraryFile.load(at: url!, limit: 3 * 1024 * 1024, decode: ShelfLocalConfiguration.decode) ?? .init() }
            catch { self.error = "The shelf layout could not be read; its original is retained: \(error.localizedDescription)"; url = nil }
        }
    }
    deinit { watcher?.cancel(); previewTask?.cancel() }
    var shelves: [CoreShelfCollection] { state.library.shelves }
    var rules: [CoreShelfRule] { state.library.rules }
    var selectedShelfID: UUID { state.selectedShelfID }
    func setEditorOpen(_ value: Bool) { editorOpen = value }
    func select(_ id: UUID) { guard shelves.contains(where: { $0.id == id }) else { return }; edit(notify: false) { $0.selectedShelfID = id } }
    @discardableResult func addShelf(_ name: String) -> Bool { edit { $0.library.shelves.append(.init(name: name.trimmingCharacters(in: .whitespacesAndNewlines))) } }
    func renameShelf(_ id: UUID, to name: String) { _ = edit { value in if let index = value.library.shelves.firstIndex(where: { $0.id == id }) { value.library.shelves[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines) } } }
    @discardableResult func saveRule(_ rule: CoreShelfRule) -> Bool {
        let saved = edit { value in
            if let index = value.library.rules.firstIndex(where: { $0.id == rule.id }) { value.library.rules[index] = rule } else { value.library.rules.append(rule) }
            value.enabledRuleIDs.remove(rule.id)
        }
        if saved { preview = nil; startIfConfigured() }; return saved
    }
    func removeRule(_ id: UUID) { if edit({ value in value.library.rules.removeAll { $0.id == id }; value.enabledRuleIDs.remove(id); value.folderBookmarks.removeValue(forKey: id.uuidString) }) { preview = nil; startIfConfigured() } }
    func moveRule(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return }
        _ = edit { $0.library.rules.swapAt(index, index + offset) }
    }
    func isEnabled(_ id: UUID) -> Bool { state.enabledRuleIDs.contains(id) }
    func disableRule(_ id: UUID) { if edit(notify: false, { $0.enabledRuleIDs.remove(id) }) { startIfConfigured() } }
    func enablePreviewedRule(_ id: UUID) {
        guard let preview, preview.rule.id == id, rules.contains(preview.rule), Date().timeIntervalSince(preview.createdAt) <= 300 else {
            error = "Preview this exact rule again before enabling it."; return
        }
        if preview.rule.kind == .watchFolder && state.folderBookmarks[id.uuidString] == nil { error = "Choose the watched folder on this Mac first."; return }
        if edit(notify: false, { $0.enabledRuleIDs.insert(id) }) { startIfConfigured() }
    }
    func chooseFolder(for rule: CoreShelfRule) {
        guard rule.kind == .watchFolder, rules.contains(rule) else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to watch. Preview its regular files before explicitly enabling this rule; originals remain unchanged."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do { try configureWatchedFolder(selected, ruleID: rule.id) } catch { self.error = "Could not retain folder access: \(error.localizedDescription)" }
    }
    func configureWatchedFolder(_ selected: URL, ruleID: UUID) throws {
        guard rules.contains(where: { $0.id == ruleID && $0.kind == .watchFolder }), selected.isFileURL else { throw CocoaError(.fileReadNoPermission) }
        do {
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard edit(notify: false, { $0.folderBookmarks[ruleID.uuidString] = bookmark; $0.enabledRuleIDs.remove(ruleID) }) else { throw SyncFailure.invalid(error ?? "Folder configuration could not be saved.") }
            preview = nil; startIfConfigured()
        } catch { throw error }
    }
    func previewWatchRule(_ rule: CoreShelfRule) {
        previewTask?.cancel()
        do {
            let folder = try resolveFolder(rule)
            previewTask = Task { @MainActor [weak self] in
                let granted = folder.startAccessingSecurityScopedResource(); defer { if granted { folder.stopAccessingSecurityScopedResource() } }
                do {
                    let child = Task.detached { try Self.scan(folder, rule: rule) }
                    let files = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
                    try Task.checkCancellation(); guard let self, self.rules.contains(rule) else { return }
                    self.preview = ShelfRulePreview(rule: rule, lines: files.map(\.lastPathComponent), fileURLs: files, cleanupIDs: [])
                    self.error = nil
                } catch is CancellationError {} catch { if !Task.isCancelled { self?.error = "Folder preview failed; no access or import is assumed: \(error.localizedDescription)" } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func resolveFolder(_ rule: CoreShelfRule) throws -> URL {
        guard let bookmark = state.folderBookmarks[rule.id.uuidString] else { throw SyncFailure.invalid("Choose this watched folder on this Mac. Folder paths and bookmarks are not synced.") }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw SyncFailure.invalid("Folder access is stale. Choose it again explicitly.") }; return folder
    }
    private nonisolated static func scan(_ folder: URL, rule: CoreShelfRule) throws -> [URL] {
        let metadata = try folder.resourceValues(forKeys: [.isDirectoryKey]); guard metadata.isDirectory == true else { throw CocoaError(.fileReadNoPermission) }
        let values = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        guard values.count <= 2_000 else { throw SyncFailure.invalid("This folder has over 2,000 entries; choose a smaller watched folder.") }
        var candidates: [URL] = []
        for url in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 100 * 1024 * 1024,
                  rule.fileExtensions.isEmpty || rule.fileExtensions.contains(url.pathExtension.lowercased()) else { continue }
            candidates.append(url)
        }
        guard candidates.count <= 200 else { throw SyncFailure.invalid("More than 200 files match this rule. Narrow its extensions before enabling.") }; return candidates
    }
    func markImported(_ url: URL, ruleID: UUID) { seen[ruleID, default: []].insert(url.standardizedFileURL) }
    func startIfConfigured() {
        stopWatching()
        for rule in rules where rule.kind == .watchFolder && isEnabled(rule.id) {
            do { let folder = try resolveFolder(rule); if folder.startAccessingSecurityScopedResource() { grantedFolders.insert(rule.id) }; watchedFolders[rule.id] = folder }
            catch { self.error = "A watched folder is unavailable; no files were added: \(error.localizedDescription)" }
        }
        guard !watchedFolders.isEmpty else { return }
        let ticket = generation; watching = true
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == ticket else { return }
                for rule in self.rules where self.watchedFolders[rule.id] != nil && self.isEnabled(rule.id) {
                    guard let folder = self.watchedFolders[rule.id] else { continue }
                    do {
                        let child = Task.detached(priority: .utility) { try Self.scan(folder, rule: rule) }
                        let files = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
                        try Task.checkCancellation(); guard self.generation == ticket else { return }
                        let new = files.filter { !self.seen[rule.id, default: []].contains($0.standardizedFileURL) }
                        if !new.isEmpty { self.onWatchedFiles?(new, rule) }
                    } catch is CancellationError { return } catch {
                        guard self.generation == ticket, !Task.isCancelled else { return }
                        self.error = "Watched folder read failed; no import is assumed: \(error.localizedDescription)"
                    }
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    private func stopWatching() {
        generation = UUID(); watcher?.cancel(); watcher = nil; watching = false
        for (id, folder) in watchedFolders where grantedFolders.contains(id) { folder.stopAccessingSecurityScopedResource() }; watchedFolders = [:]; grantedFolders = []
    }
    func shutdown() { stopWatching(); previewTask?.cancel(); previewTask = nil }
    func exportSyncedLibrary() throws -> CoreShelfConfiguration { try validateOriginal(); return state.library }
    func validateSyncedLibrary(_ value: CoreShelfConfiguration) throws {
        try validateOriginal(); _ = try value.encoded()
        guard !editorOpen || state.library == value else { throw SyncFailure.invalid("Close the shelf rule editor before applying changed shared rules; drafts are retained.") }
    }
    func applySyncedLibrary(_ value: CoreShelfConfiguration) throws {
        try validateSyncedLibrary(value); var next = state
        let unchanged = Set(value.rules.filter { state.library.rules.contains($0) }.map(\.id))
        next.enabledRuleIDs.formIntersection(unchanged); next.library = value
        if !value.shelves.contains(where: { $0.id == next.selectedShelfID }) { next.selectedShelfID = CoreShelfCollection.inboxID }
        next.folderBookmarks = next.folderBookmarks.filter { unchanged.contains(UUID(uuidString: $0.key) ?? UUID()) }
        try persist(next); preview = nil; startIfConfigured()
    }
    func prepareSyncRollback() -> @MainActor () -> Void {
        let previous = state, oldError = error, oldPreview = preview
        return { self.state = previous; self.error = oldError; self.preview = oldPreview; self.startIfConfigured() }
    }
    private func validateOriginal() throws {
        guard let url else { throw SyncFailure.invalid("The unreadable shelf layout original is retained.") }
        if persistState { _ = try PlusPortableLibraryFile.load(at: url, limit: 3 * 1024 * 1024, decode: ShelfLocalConfiguration.decode) }
    }
    private func persist(_ value: ShelfLocalConfiguration) throws {
        try value.validate(); try validateOriginal()
        if persistState, let url { try PlusPortableLibraryFile.save(JSONEncoder().encode(value), at: url, limit: 3 * 1024 * 1024, decode: ShelfLocalConfiguration.decode) }
        state = value; error = nil
    }
    @discardableResult private func edit(notify: Bool = true, _ change: (inout ShelfLocalConfiguration) -> Void) -> Bool {
        do { var next = state; change(&next); try persist(next); if notify { onChange() }; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
