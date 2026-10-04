import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotchCore

private struct ShelfTrashEntry: Codable { let item: FileShelfItem; let metadata: ShelfFileMetadata }
private struct ShelfTrashRecord: Codable {
    let id: UUID
    let removedAt: Date
    let entries: [ShelfTrashEntry]
}

@MainActor
final class FileShelfToolStore: ObservableObject {
    private static var instance: FileShelfToolStore?
    static var shared: FileShelfToolStore {
        if let instance { return instance }
        let store = FileShelfToolStore()
        instance = store
        return store
    }
    static func shutdownIfInitialized() { instance?.shutdown() }

    @Published private(set) var items: [FileShelfItem] = []
    @Published private(set) var metadata: [String: ShelfFileMetadata] = [:]
    @Published var autoSave = false { didSet { save() } }
    @Published var retention: ShelfRetention = .week { didSet { pruneExpired(); save() } }
    @Published var error: String?
    @Published var status = "Drop local files here or choose Add Files."
    @Published private(set) var importing = 0
    @Published private(set) var cleanupPreview: CoreShelfCleanupPlan?
    @Published private(set) var canUndoRemoval = false
    @Published private(set) var expiryRequiresRetry = false
    let collections: ShelfCollectionsStore
    private var lastTrash: ShelfTrashRecord?
    private var managedDirectory: URL?
    private var expiration: Task<Void, Never>?
    private var inFlight = Set<URL>()
    private var scopedURLs: [UUID: URL] = [:]
    private let persistState: Bool
    private let suppliedIndexDirectory: URL?
    private let previews = ShelfQuickLookController()

    init(managedDirectory suppliedDirectory: URL? = nil, persistState: Bool = true,
         archive suppliedArchive: ShelfLibraryArchive? = nil,
         onPortableChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.portableDidChange() }) {
        self.persistState = persistState
        suppliedIndexDirectory = suppliedDirectory
        let layoutDirectory = suppliedDirectory ?? ((try? LocalToolStorage.directory()) ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        collections = ShelfCollectionsStore(directory: layoutDirectory, persistState: persistState, onChange: onPortableChange)
        do {
            let directory: URL
            if let suppliedDirectory { directory = suppliedDirectory }
            else { directory = try LocalToolStorage.directory().appendingPathComponent("ShelfFiles", isDirectory: true) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            managedDirectory = directory
            expiryRequiresRetry = try PlusSyncFolderIO.hasNode(directory.appendingPathComponent("expiry-requires-retry.txt"))
            let archive = try suppliedArchive ?? (persistState
                ? try suppliedDirectory.map { try PlusPortableLibraryFile.load(at: $0.appendingPathComponent("file-shelf.json"), limit: 40 * 1024 * 1024, decode: { try JSONDecoder().decode(ShelfLibraryArchive.self, from: $0) }) ?? .init() }
                    ?? LocalToolStorage.load(ShelfLibraryArchive.self, file: "file-shelf.json", fallback: .init())
                : ShelfLibraryArchive())
            items = archive.state.items; autoSave = archive.state.autoSave; retention = archive.state.retention
            metadata = archive.metadata
            pruneExpired()
            loadLastTrash()
            collections.onWatchedFiles = { [weak self] urls, rule in
                for url in urls { self?.add(url, shelfID: rule.shelfID, tags: rule.tags, forceCopy: true, watchedRuleID: rule.id) }
            }
            collections.onLocalExpiryChange = { [weak self] in self?.pruneExpired() }
            pruneExpired()
        } catch { self.error = "Could not open the local file shelf: \(error.localizedDescription)" }
    }
    deinit {
        expiration?.cancel()
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
    }

    private func save() {
        guard persistState else { scheduleExpiration(); return }
        do {
            try persistIndex(items: items, metadata: metadata)
            scheduleExpiration()
        } catch { self.error = "Could not save the shelf index: \(error.localizedDescription)" }
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        if panel.runModal() == .OK { for url in panel.urls { add(url) } }
    }

    @discardableResult
    func receive(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, failure in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                let message = failure?.localizedDescription ?? "The dropped item has no usable file URL."
                Task { @MainActor [weak self] in
                    if let url { self?.add(url) }
                    else { self?.error = "Could not receive dropped file: \(message)" }
                }
            }
        }
        return true
    }

    func add(_ url: URL, shelfID: UUID? = nil, tags: [String] = [], forceCopy: Bool? = nil, watchedRuleID: UUID? = nil) {
        let host = (url.host ?? "").lowercased()
        guard url.isFileURL, host.isEmpty || host == "localhost", !url.path.isEmpty else {
            error = "The shelf accepts local file URLs only."
            return
        }
        let original = url.standardizedFileURL
        guard items.count + inFlight.count < 200 else { error = "The shelf holds at most 200 entries."; return }
        guard !inFlight.contains(original), !items.contains(where: { $0.originalURL.standardizedFileURL == original }) else {
            if let watchedRuleID, items.contains(where: { $0.originalURL.standardizedFileURL == original }) { collections.markImported(original, ruleID: watchedRuleID) }
            status = "This file is already on the shelf."
            return
        }
        guard let directory = managedDirectory else { error = "The local shelf directory is unavailable."; return }
        let copy = forceCopy ?? autoSave, targetShelf = shelfID ?? collections.selectedShelfID
        inFlight.insert(original); importing += 1
        Task { @MainActor [weak self] in
            // Finish indexing an in-flight copy even if the user changes tools.
            guard let self else { return }
            defer { self.inFlight.remove(original); self.importing -= 1 }
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try FileShelfToolStore.prepare(original, copy: copy, directory: directory)
                }.value
                do { try self.publish(item, shelfID: targetShelf, tags: tags) }
                catch { try self.deleteManagedCopy(item); throw error }
                if let watchedRuleID { self.collections.markImported(original, ruleID: watchedRuleID) }
                self.error = nil
                self.status = copy ? "Saved a managed copy; the original is unchanged." : "Added a durable reference; the original is unchanged."
            } catch {
                self.error = "Could not add \(original.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Generated captures always become owned shelf copies, independent of the drop Auto-save preference.
    /// Await publication before the capture subsystem removes its private staging file.
    func addManagedCapture(_ url: URL,
                           isCurrent: @MainActor () -> Bool = { true },
                           didPublish: @MainActor (FileShelfItem) -> Void = { _ in }) async throws -> FileShelfItem {
        guard ["png", "mov", "mp4"].contains(url.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rule = collections.rules.first { $0.kind == .captures && collections.isEnabled($0.id) && ($0.fileExtensions.isEmpty || $0.fileExtensions.contains(url.pathExtension.lowercased())) }
        return try await addManagedFile(url, shelfID: rule?.shelfID, tags: rule?.tags ?? ["Capture"], isCurrent: isCurrent, didPublish: { [self] item in
            status = "Saved a managed capture; its staging source is unchanged."
            didPublish(item)
        })
    }

    /// Explicit file imports await a durable owned copy of any regular local file.
    /// Publication and the caller's completion callback share one MainActor turn.
    func addManagedFile(_ url: URL,
                        shelfID: UUID? = nil, tags: [String] = [],
                        isCurrent: @MainActor () -> Bool = { true },
                        didPublish: @MainActor (FileShelfItem) -> Void = { _ in }) async throws -> FileShelfItem {
        try Task.checkCancellation()
        let targetShelf = shelfID ?? collections.selectedShelfID
        let source = url.standardizedFileURL
        guard source.isFileURL, (source.host ?? "").isEmpty || source.host == "localhost" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              items.count + inFlight.count < 200, !inFlight.contains(source),
              let directory = managedDirectory else { throw CocoaError(.fileReadCorruptFile) }
        inFlight.insert(source); importing += 1
        defer { inFlight.remove(source); importing -= 1 }
        let child = Task.detached(priority: .userInitiated) {
            try Self.prepare(source, copy: true, directory: directory)
        }
        let item = try await withTaskCancellationHandler {
            try await child.value
        } onCancel: { child.cancel() }
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try publish(item, shelfID: targetShelf, tags: tags)
            error = nil; status = "Saved a managed file; its original is unchanged."
            scheduleExpiration()
            // The caller's completion commit shares this MainActor turn; a
            // cancelled caller never needs to remove a user-editable published item.
            didPublish(item)
            return item
        } catch {
            try deleteManagedCopy(item)
            throw error
        }
    }

    private func publish(_ item: FileShelfItem, shelfID: UUID, tags: [String]) throws {
        guard collections.shelves.contains(where: { $0.id == shelfID }) else { throw SyncFailure.invalid("The destination shelf changed while the file was copied. Choose a current shelf and retry.") }
        var nextMetadata = metadata
        nextMetadata[item.id.uuidString] = ShelfFileMetadata(tags: tags, shelfID: shelfID)
        try persistIndex(items: [item] + items, metadata: nextMetadata)
        items.insert(item, at: 0); metadata = nextMetadata
    }
    private func persistIndex(items: [FileShelfItem], metadata: [String: ShelfFileMetadata]) throws {
        guard persistState else { return }
        let value = ShelfLibraryArchive(state: FileShelfState(items: items, autoSave: autoSave, retention: retention), metadata: metadata)
        if let suppliedIndexDirectory {
            try PlusPortableLibraryFile.save(JSONEncoder().encode(value), at: suppliedIndexDirectory.appendingPathComponent("file-shelf.json"), limit: 40 * 1024 * 1024, decode: { try JSONDecoder().decode(ShelfLibraryArchive.self, from: $0) })
        } else { try LocalToolStorage.save(value, file: "file-shelf.json") }
    }
    private func indexURL() throws -> URL? { persistState ? try (suppliedIndexDirectory ?? LocalToolStorage.directory()).appendingPathComponent("file-shelf.json") : nil }
    func shelfID(for item: FileShelfItem) -> UUID {
        let id = info(for: item).shelfID ?? CoreShelfCollection.inboxID
        return collections.shelves.contains(where: { $0.id == id }) ? id : CoreShelfCollection.inboxID
    }
    @discardableResult func move(_ ids: [UUID], to shelfID: UUID) -> Bool {
        guard collections.shelves.contains(where: { $0.id == shelfID }), !ids.isEmpty, ids.allSatisfy({ id in items.contains(where: { $0.id == id }) }) else { error = "Choose existing shelf entries and a valid destination."; return false }
        do {
            var next = metadata
            for id in ids { var info = next[id.uuidString] ?? .init(); info.shelfID = shelfID; next[id.uuidString] = info }
            try persistIndex(items: items, metadata: next); metadata = next; status = "Moved shelf metadata; all file contents and originals are unchanged."; error = nil; pruneExpired(); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private nonisolated static func prepare(_ source: URL, copy: Bool, directory: URL) throws -> FileShelfItem {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        var sourceIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let bookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = UUID()
        guard copy else { return FileShelfItem(id: id, originalURL: source, bookmark: bookmark) }
        if sourceIsDirectory.boolValue {
            let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
            let copyPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            guard copyPath != sourcePath, !copyPath.hasPrefix(prefix) else {
                throw NSError(domain: "NotchOrbitPlus.Shelf", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot auto-save a folder inside itself. Turn off Auto-save copies to keep a reference instead."])
            }
        }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            return FileShelfItem(id: id, originalURL: source, managedURL: destination, bookmark: bookmark)
        } catch {
            do { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
            catch { throw NSError(domain: "NotchOrbitPlus.Shelf", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Copy failed and its incomplete managed folder could not be removed: \(error.localizedDescription)"] ) }
            throw error
        }
    }

    func resolve(_ item: FileShelfItem) -> URL? {
        do {
            let url: URL
            if let managed = item.managedURL { url = managed }
            else if let bookmark = item.bookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } else { url = item.originalURL }
            if scopedURLs[item.id] == nil, url.startAccessingSecurityScopedResource() { scopedURLs[item.id] = url }
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            return url
        } catch {
            self.error = "\(item.originalURL.lastPathComponent) is unavailable: \(error.localizedDescription)"
            return nil
        }
    }

    func reveal(_ item: FileShelfItem) {
        guard let url = resolve(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func info(for item: FileShelfItem) -> ShelfFileMetadata { metadata[item.id.uuidString] ?? .init() }
    func toggleFavourite(_ item: FileShelfItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        var info = info(for: item)
        info.favourite.toggle()
        metadata[item.id.uuidString] = info
        error = nil
        save()
    }
    @discardableResult
    func setTags(_ value: String, for item: FileShelfItem) -> Bool {
        guard items.contains(where: { $0.id == item.id }) else { error = "This shelf entry is no longer available."; return false }
        let tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard tags.count <= 20, tags.allSatisfy({ $0.count <= 40 && $0.utf8.count <= 512 }) else {
            error = "Use up to 20 short tags, each at most 40 characters."
            return false
        }
        metadata[item.id.uuidString] = ShelfFileMetadata(tags: tags, favourite: info(for: item).favourite, shelfID: info(for: item).shelfID)
        error = nil
        save()
        return error == nil
    }
    func preview(_ item: FileShelfItem) {
        guard let url = resolve(item) else { return }
        do {
            try previews.show(url: url, itemID: item.id)
            error = nil
            status = "Opened Quick Look for \(url.lastPathComponent)."
        } catch { self.error = "Could not preview this file: \(error.localizedDescription)" }
    }
    func airDrop(_ item: FileShelfItem) {
        guard let url = resolve(item) else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            error = "AirDrop is unavailable for this file on this Mac."
            return
        }
        service.perform(withItems: [url])
        status = "AirDrop opened for \(url.lastPathComponent)."
    }

    private func deleteManagedCopy(_ item: FileShelfItem) throws {
        previews.close(ifShowing: item.id)
        guard let folder = try ownedFolder(for: item) else { return }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    private func ownedFolder(for item: FileShelfItem, protecting additionalOriginals: [URL] = []) throws -> URL? {
        guard let managed = item.managedURL else { return nil }
        guard managed.isFileURL, item.originalURL.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
        guard let directory = managedDirectory else { throw CocoaError(.fileWriteUnknown) }
        let folder = directory.appendingPathComponent(item.id.uuidString, isDirectory: true).standardizedFileURL
        // Only the uniquely owned copy folder can be removed. References and
        // every original URL are excluded, including imported/tampered state.
        guard managed.standardizedFileURL.deletingLastPathComponent().path == folder.path,
              !CoreShelfCleanupPlan.folderContainsOriginal(folder, originalURLs: items.map(\.originalURL) + [item.originalURL] + additionalOriginals),
              folder.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw NSError(domain: "NotchOrbitPlus.Shelf", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Refused to move an unowned folder or a folder containing an indexed original or reference."])
        }
        if try PlusSyncFolderIO.hasNode(folder) {
            try CoreShelfCleanupPlan.validateOwnedFileFolder(folder, managedFileName: managed.lastPathComponent)
        }
        return folder
    }

    func remove(_ item: FileShelfItem) {
        do {
            try retainInTrash([item])
            error = nil; status = "Removed shelf entry. Undo restores its retained copy; its original file is unchanged."
        } catch { self.error = "Could not remove shelf entry: \(error.localizedDescription)" }
    }

    func pruneExpired() {
        guard let managedDirectory else { return }
        applyEnabledExpiryRules()
        let now = Date()
        var ids: Set<UUID> = []
        if let duration = retention.duration { ids.formUnion(CoreShelfCleanupPlan.preview(items: items, managedRoot: managedDirectory, olderThan: now.addingTimeInterval(-duration), now: now).itemIDs) }
        for rule in collections.rules where rule.kind == .expireOwnedCopies && collections.isEnabled(rule.id) {
            let eligible = items.filter { shelfID(for: $0) == rule.shelfID }
            ids.formUnion(CoreShelfCleanupPlan.preview(items: eligible, managedRoot: managedDirectory, olderThan: now.addingTimeInterval(-Double(rule.days) * 86_400), now: now, protectedOriginalURLs: items.map(\.originalURL)).itemIDs)
        }
        cleanupPreview = CoreShelfCleanupPlan(itemIDs: items.map(\.id).filter { ids.contains($0) }, excludedReferences: items.filter { $0.managedURL == nil && $0.expired(at: now, retention: retention) }.count, generatedAt: now)
        if !ids.isEmpty { status = "\(ids.count) owned copy/copies are eligible. Preview and confirm cleanup; nothing was deleted automatically." }
        scheduleExpiration()
    }
    private func scheduleExpiration() {
        expiration?.cancel(); expiration = nil
        let now = Date()
        var deadlines: [Date] = []
        if let duration = retention.duration { deadlines += items.map { $0.addedAt.addingTimeInterval(duration) } }
        if !expiryRequiresRetry {
            for rule in collections.rules where rule.kind == .expireOwnedCopies && collections.isEnabled(rule.id) {
                deadlines += items.filter { shelfID(for: $0) == rule.shelfID && $0.managedURL != nil }.map { $0.addedAt.addingTimeInterval(Double(rule.days) * 86_400) }
            }
        }
        // Failed cleanup waits for an explicit retry; do not repeatedly wake
        // for the same expired entry when its filesystem error is unchanged.
        guard let next = deadlines.filter({ $0 > now }).min() else { return }
        let seconds = max(1, next.timeIntervalSince(now))
        expiration = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.pruneExpired()
        }
    }
    private func applyEnabledExpiryRules() {
        guard !expiryRequiresRetry, let managedDirectory else { return }
        let now = Date()
        var ids: Set<UUID> = []
        for rule in collections.rules where rule.kind == .expireOwnedCopies && collections.isEnabled(rule.id) {
            let eligible = items.filter { shelfID(for: $0) == rule.shelfID }
            ids.formUnion(CoreShelfCleanupPlan.preview(items: eligible, managedRoot: managedDirectory,
                olderThan: now.addingTimeInterval(-Double(rule.days) * 86_400), now: now, protectedOriginalURLs: items.map(\.originalURL)).itemIDs)
        }
        guard !ids.isEmpty else { return }
        do {
            // This private marker survives a crash or failed rollback. No further
            // background retry occurs until the user explicitly clears it.
            let marker = managedDirectory.appendingPathComponent("expiry-requires-retry.txt")
            try Data("Automatic shelf expiry requires explicit retry if this marker remains.\n".utf8).write(to: marker, options: .atomic)
            expiryRequiresRetry = true
            try retainInTrash(items.filter { ids.contains($0.id) })
            try FileManager.default.removeItem(at: marker)
            expiryRequiresRetry = false
            collections.preview = nil; error = nil
            status = "Background expiry moved \(ids.count) managed copies to retained Undo trash. Originals and references are unchanged."
        } catch {
            expiryRequiresRetry = true
            self.error = "Automatic expiry paused after a local IO error. Retained recovery copies are preserved; explicitly retry after resolving the cause: \(error.localizedDescription)"
        }
    }
    func retryAutomaticExpiry() {
        do {
            guard let managedDirectory else { throw CocoaError(.fileWriteUnknown) }
            let marker = managedDirectory.appendingPathComponent("expiry-requires-retry.txt")
            if try PlusSyncFolderIO.hasNode(marker) {
                _ = try PlusSyncFolderIO.boundedData(marker, limit: 1_024)
                try FileManager.default.removeItem(at: marker)
            }
            expiryRequiresRetry = false; pruneExpired()
        } catch { expiryRequiresRetry = true; self.error = "Automatic expiry remains paused: \(error.localizedDescription)" }
    }

    func previewRule(_ rule: CoreShelfRule) {
        guard collections.rules.contains(rule), let managedDirectory else { return }
        switch rule.kind {
        case .watchFolder: collections.previewWatchRule(rule)
        case .captures:
            collections.preview = ShelfRulePreview(rule: rule, lines: ["Future captures become owned copies in \(collections.shelves.first(where: { $0.id == rule.shelfID })?.name ?? "Inbox").", "Tags: \(rule.tags.joined(separator: ", "))", "Formats: \(rule.fileExtensions.isEmpty ? "PNG / MOV / MP4" : rule.fileExtensions.joined(separator: ", "))"], fileURLs: [], cleanupIDs: [])
        case .expireOwnedCopies:
            let matching = items.filter { shelfID(for: $0) == rule.shelfID }
            let plan = CoreShelfCleanupPlan.preview(items: matching, managedRoot: managedDirectory, olderThan: Date().addingTimeInterval(-Double(rule.days) * 86_400), protectedOriginalURLs: items.map(\.originalURL))
            collections.preview = ShelfRulePreview(rule: rule, lines: items.filter { plan.itemIDs.contains($0.id) }.map { $0.originalURL.lastPathComponent }, fileURLs: [], cleanupIDs: plan.itemIDs)
        }
    }
    func confirmCleanup(_ ids: [UUID]) {
        do {
            guard let managedDirectory, Set(ids).count == ids.count, !ids.isEmpty else { throw SyncFailure.invalid("Preview the owned copies to clean up first.") }
            let selected = items.filter { ids.contains($0.id) }
            guard selected.count == ids.count else { throw SyncFailure.invalid("The shelf changed; preview again before confirming cleanup.") }
            let eligible = CoreShelfCleanupPlan.preview(items: selected, managedRoot: managedDirectory, olderThan: .distantFuture, protectedOriginalURLs: items.map(\.originalURL))
            guard eligible.itemIDs.count == selected.count else { throw SyncFailure.invalid("Cleanup excludes references, originals and unowned paths.") }
            try retainInTrash(selected); cleanupPreview = nil; error = nil
            status = "Retained \(selected.count) owned copies in private trash. Undo is available; originals are unchanged."
        } catch { self.error = "Cleanup did not finish: \(error.localizedDescription)" }
    }
    private func trashRoot() throws -> URL {
        guard let managedDirectory else { throw CocoaError(.fileWriteUnknown) }
        let url = managedDirectory.appendingPathComponent("ShelfTrash", isDirectory: true)
        if try PlusSyncFolderIO.hasNode(url) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return url
    }
    private func retainInTrash(_ removed: [FileShelfItem]) throws {
        guard !removed.isEmpty, removed.allSatisfy({ item in items.contains(where: { $0.id == item.id }) }) else { throw CocoaError(.fileNoSuchFile) }
        let folders = try removed.compactMap { item -> (UUID, URL)? in try ownedFolder(for: item).map { (item.id, $0) } }
        let root = try trashRoot(), record = ShelfTrashRecord(id: UUID(), removedAt: Date(), entries: removed.map { .init(item: $0, metadata: info(for: $0)) })
        let batch = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let recordBytes = try JSONEncoder().encode(record)
        guard recordBytes.count <= 16 * 1024 * 1024 else { throw SyncFailure.invalid("The retained undo record exceeds 16 MB; nothing was removed.") }
        try recordBytes.write(to: batch.appendingPathComponent("undo.json"), options: .atomic)
        let indexURL = try indexURL()
        let originalIndex = try indexURL.flatMap { try PlusSyncFolderIO.hasNode($0) ? PlusSyncFolderIO.boundedData($0, limit: 40 * 1024 * 1024) : nil }
        if let originalIndex { try originalIndex.write(to: batch.appendingPathComponent("index-before.json"), options: .atomic) }
        var moved: [(UUID, URL)] = []
        do {
            for (id, folder) in folders {
                try FileManager.default.moveItem(at: folder, to: batch.appendingPathComponent(id.uuidString, isDirectory: true)); moved.append((id, folder))
            }
            let ids = Set(removed.map(\.id)), nextItems = items.filter { !ids.contains($0.id) }, nextMetadata = metadata.filter { !ids.contains(UUID(uuidString: $0.key) ?? UUID()) }
            try persistIndex(items: nextItems, metadata: nextMetadata)
            items = nextItems; metadata = nextMetadata
            for item in removed { previews.close(ifShowing: item.id); if let url = scopedURLs.removeValue(forKey: item.id) { url.stopAccessingSecurityScopedResource() } }
            lastTrash = record; canUndoRemoval = true; scheduleExpiration()
        } catch {
            var recovered = true
            for (id, folder) in moved.reversed() { do { try FileManager.default.moveItem(at: batch.appendingPathComponent(id.uuidString), to: folder) } catch { recovered = false } }
            if let indexURL { do { if let originalIndex { try originalIndex.write(to: indexURL, options: .atomic) } else if try PlusSyncFolderIO.hasNode(indexURL) { try FileManager.default.removeItem(at: indexURL) } } catch { recovered = false } }
            if recovered { try? FileManager.default.removeItem(at: batch); throw error }
            throw SyncFailure.invalid("Shelf cleanup recovery was incomplete. Retained originals and the prior index remain in ShelfTrash/\(record.id.uuidString); restore them before more cleanup.")
        }
    }
    private func loadLastTrash() {
        do {
            guard let managedDirectory,
                  try PlusSyncFolderIO.hasNode(managedDirectory.appendingPathComponent("ShelfTrash", isDirectory: true)) else { return }
            let root = try trashRoot()
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folders.count <= 1_000 else { return }
            var records: [ShelfTrashRecord] = []
            for folder in folders {
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      (try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                let file = folder.appendingPathComponent("undo.json")
                guard try PlusSyncFolderIO.hasNode(file) else { continue }
                let record = try JSONDecoder().decode(ShelfTrashRecord.self, from: PlusSyncFolderIO.boundedData(file, limit: 16 * 1024 * 1024))
                guard record.id.uuidString == folder.lastPathComponent, record.entries.count <= 200,
                      Set(record.entries.map { $0.item.id }).count == record.entries.count,
                      !record.entries.contains(where: { entry in items.contains(where: { $0.id == entry.item.id }) }) else { continue }
                do {
                    _ = try restorationFolders(for: record, batch: folder)
                    records.append(record)
                } catch { self.error = "Retained shelf copies were left untouched because safe Undo is unavailable: \(error.localizedDescription)" }
            }
            lastTrash = records.max(by: { $0.removedAt < $1.removedAt }); canUndoRemoval = lastTrash != nil
        } catch { self.error = "Retained shelf copies could not be read: \(error.localizedDescription)" }
    }
    private func restorationFolders(for record: ShelfTrashRecord, batch: URL) throws -> [(source: URL, destination: URL)] {
        let batchInfo = try batch.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard batchInfo.isDirectory == true, batchInfo.isSymbolicLink != true,
              batch.resolvingSymlinksInPath().deletingLastPathComponent().path == (try trashRoot()).resolvingSymlinksInPath().standardizedFileURL.path else { throw CocoaError(.fileReadCorruptFile) }
        let originals = items.map(\.originalURL) + record.entries.map { $0.item.originalURL }
        return try record.entries.compactMap { entry in
            guard let managed = entry.item.managedURL,
                  let destination = try ownedFolder(for: entry.item, protecting: originals) else { return nil }
            let source = batch.appendingPathComponent(entry.item.id.uuidString, isDirectory: true)
            guard !CoreShelfCleanupPlan.folderContainsOriginal(source, originalURLs: originals) else {
                throw SyncFailure.invalid("The retained folder contains an indexed original or reference; it cannot be moved by Undo.")
            }
            let info = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard !(try PlusSyncFolderIO.hasNode(destination)), info.isSymbolicLink != true, info.isDirectory == true,
                  source.resolvingSymlinksInPath().deletingLastPathComponent().path == batch.resolvingSymlinksInPath().standardizedFileURL.path else { throw CocoaError(.fileWriteFileExists) }
            try CoreShelfCleanupPlan.validateOwnedFileFolder(source, managedFileName: managed.lastPathComponent)
            return (source, destination)
        }
    }
    func undoRemoval() {
        guard let record = lastTrash else { return }
        do {
            guard items.count + record.entries.count <= 200, record.entries.allSatisfy({ entry in !items.contains(where: { $0.id == entry.item.id }) }) else { throw SyncFailure.invalid("Undo would duplicate entries or exceed 200 files; current originals are unchanged.") }
            let batch = try trashRoot().appendingPathComponent(record.id.uuidString, isDirectory: true)
            // Check every source and destination before any move or setting change.
            // A reference may have been added after this Undo record was loaded.
            let folders = try restorationFolders(for: record, batch: batch)
            let shelfIDs = Set(record.entries.map { entry in
                let id = entry.metadata.shelfID ?? CoreShelfCollection.inboxID
                return collections.shelves.contains(where: { $0.id == id }) ? id : CoreShelfCollection.inboxID
            })
            try collections.disableExpiryRules(for: shelfIDs)
            let indexURL = try indexURL()
            let previousIndex = try indexURL.flatMap { try PlusSyncFolderIO.hasNode($0) ? PlusSyncFolderIO.boundedData($0, limit: 40 * 1024 * 1024) : nil }
            if let previousIndex { try previousIndex.write(to: batch.appendingPathComponent("index-before-undo.json"), options: .atomic) }
            var moved: [(URL, URL)] = []
            do {
                for (source, destination) in folders {
                    try FileManager.default.moveItem(at: source, to: destination); moved.append((source, destination))
                }
                var nextMetadata = metadata; for entry in record.entries { nextMetadata[entry.item.id.uuidString] = entry.metadata }
                let nextItems = record.entries.map(\.item) + items
                try persistIndex(items: nextItems, metadata: nextMetadata); items = nextItems; metadata = nextMetadata
            } catch {
                var restored = true
                for (source, destination) in moved.reversed() { do { try FileManager.default.moveItem(at: destination, to: source) } catch { restored = false } }
                if let indexURL {
                    do { if let previousIndex { try previousIndex.write(to: indexURL, options: .atomic) } else if try PlusSyncFolderIO.hasNode(indexURL) { try FileManager.default.removeItem(at: indexURL) } }
                    catch { restored = false }
                }
                if !restored { throw SyncFailure.invalid("Undo recovery was incomplete. Retained copies remain in \(batch.path); review them before further cleanup.") }; throw error
            }
            try? FileManager.default.removeItem(at: batch.appendingPathComponent("undo.json"))
            lastTrash = nil; canUndoRemoval = false; error = nil; status = "Restored shelf entries and retained copies. Originals are unchanged."; pruneExpired()
        } catch { self.error = "Could not undo shelf removal: \(error.localizedDescription)" }
    }
    func shutdown() {
        expiration?.cancel(); expiration = nil
        previews.close()
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        collections.shutdown()
    }
}

@MainActor
private struct ShelfShareButton: NSViewRepresentable {
    let resolve: () -> URL?
    func makeCoordinator() -> Coordinator { Coordinator(resolve: resolve) }
    func makeNSView(context: Context) -> NSButton {
        NSButton(title: "Share", target: context.coordinator, action: #selector(Coordinator.share(_:)))
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.resolve = resolve }
    @MainActor final class Coordinator: NSObject {
        var resolve: () -> URL?
        private var picker: NSSharingServicePicker?
        init(resolve: @escaping () -> URL?) { self.resolve = resolve; super.init() }
        @objc func share(_ sender: NSButton) {
            guard let url = resolve() else { return }
            let picker = NSSharingServicePicker(items: [url])
            self.picker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

@MainActor
struct FileShelfToolView: View {
    @ObservedObject private var store: FileShelfToolStore
    @ObservedObject private var collections: ShelfCollectionsStore
    @State private var targeted = false
    @State private var search = ""
    @State private var favouritesOnly = false
    @State private var editingTags: FileShelfItem?
    @State private var draftTags = ""
    @State private var showSettings = false
    @State private var showCleanup = false
    init(store: FileShelfToolStore = .shared) { self.store = store; collections = store.collections }
    private var visible: [FileShelfItem] {
        ShelfLibrarySearch.filter(store.items.filter { store.shelfID(for: $0) == collections.selectedShelfID }, metadata: store.metadata, query: search, favouritesOnly: favouritesOnly)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Shelf", selection: Binding(get: { collections.selectedShelfID }, set: { collections.select($0) })) { ForEach(collections.shelves) { Text($0.name).tag($0.id) } }.frame(width: 125)
                Button("Add Files", action: store.addFiles)
                Toggle("Auto-save copies", isOn: $store.autoSave)
                Spacer()
                Picker("Keep", selection: $store.retention) {
                    ForEach(ShelfRetention.allCases) { Text($0.title).tag($0) }
                }.frame(width: 150)
            }
            ScrollView(.horizontal) {
                HStack { ForEach(collections.shelves) { shelf in
                    Button(shelf.name) { collections.select(shelf.id) }
                        .onDrop(of: ["com.notchorbitplus.shelf-entry-id"], isTargeted: nil) { providers in
                            for provider in providers {
                                provider.loadDataRepresentation(forTypeIdentifier: "com.notchorbitplus.shelf-entry-id") { data, _ in
                                    guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                                    Task { @MainActor in _ = store.move([id], to: shelf.id) }
                                }
                            }; return !providers.isEmpty
                        }
                } }
            }
            Text("Drag entries onto a shelf name to move metadata. Cleanup requires preview and confirmation; retained copies support Undo. Originals are never deleted.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Enabled background expiry rules move managed copies to retained Undo trash, including while this tool is hidden.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField("Search filenames or tags", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Favourites Only", isOn: $favouritesOnly)
            }
            LocalToolError(message: store.error)
            List(visible) { item in
                HStack {
                    Button { store.toggleFavourite(item) } label: {
                        Image(systemName: store.info(for: item).favourite ? "star.fill" : "star")
                    }.buttonStyle(.borderless).accessibilityLabel("Toggle favourite for \(item.originalURL.lastPathComponent)")
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.originalURL.lastPathComponent, systemImage: item.managedURL == nil ? "doc" : "doc.on.doc")
                        if !store.info(for: item).tags.isEmpty {
                            Text(store.info(for: item).tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .onDrag {
                            guard let url = store.resolve(item) else { return NSItemProvider() }
                            let provider = NSItemProvider(object: url as NSURL)
                            provider.registerDataRepresentation(forTypeIdentifier: "com.notchorbitplus.shelf-entry-id", visibility: .ownProcess) { completion in completion(Data(item.id.uuidString.utf8), nil); return nil }
                            return provider
                        }
                    Button {
                        draftTags = store.info(for: item).tags.joined(separator: ", ")
                        editingTags = item
                    } label: { Image(systemName: "tag") }
                        .buttonStyle(.borderless).help("Edit shelf tags").accessibilityLabel("Edit tags for \(item.originalURL.lastPathComponent)")
                    Button { store.preview(item) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("Quick Look").accessibilityLabel("Quick Look \(item.originalURL.lastPathComponent)")
                    Button("Reveal") { store.reveal(item) }.buttonStyle(.borderless)
                    ShelfShareButton(resolve: { store.resolve(item) }).frame(width: 55, height: 24)
                    Button("AirDrop") { store.airDrop(item) }.buttonStyle(.borderless)
                    Menu("Move") { ForEach(collections.shelves) { shelf in Button(shelf.name) { _ = store.move([item.id], to: shelf.id) } } }
                    Button("iPhone") { OrbitInboxStore.shared.sendFileFromShelf(item, shelf: store) }.buttonStyle(.borderless)
                    Button { store.remove(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(item.originalURL.lastPathComponent) from shelf")
                }
            }.frame(height: 200)
                .overlay {
                    if store.items.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down").font(.title2)
                            Text("Drop Files Here").font(.headline)
                            Text("Or choose Add Files. Originals stay intact.").font(.caption)
                        }.foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    } else if visible.isEmpty {
                        Text("No matching shelf entries").foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(targeted ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: targeted ? 2 : 1))
                .contentShape(Rectangle())
                .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in store.receive(providers) }
            HStack {
                if store.importing > 0 { ProgressView().controlSize(.small); Text("Adding \(store.importing) file(s)…") }
                else { Text(store.status) }
                Spacer()
                Text("\(visible.count) shown · \(store.items.count)/200")
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Shelves & Rules") { showSettings = true }
                Button("Preview Cleanup") { store.pruneExpired(); showCleanup = true }
                Button("Undo Removal") { store.undoRemoval() }.disabled(!store.canUndoRemoval)
                if store.expiryRequiresRetry { Button("Retry Expiry") { store.retryAutomaticExpiry() } }
            }
        }.padding().onAppear { store.pruneExpired(); collections.startIfConfigured() }
            .sheet(isPresented: $showSettings) { ShelfSettingsView(store: store).frame(width: 560, height: 540) }
            .sheet(isPresented: $showCleanup) { ShelfCleanupPreviewView(store: store) { showCleanup = false } }
            .sheet(item: $editingTags) { item in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tags for \(item.originalURL.lastPathComponent)").font(.headline)
                    TextField("Work, Photos, Personal", text: $draftTags).textFieldStyle(.roundedBorder)
                    Text("Comma-separated tags stay in this shelf and do not change Finder tags.")
                        .font(.caption).foregroundStyle(.secondary)
                    LocalToolError(message: store.error)
                    HStack {
                        Button("Cancel") { editingTags = nil }
                        Spacer()
                        Button("Save Tags") { if store.setTags(draftTags, for: item) { editingTags = nil } }
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding().frame(width: 360)
            }
    }
}
