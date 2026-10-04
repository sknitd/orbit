import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotchCore

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
    @Published var autoSave = false { didSet { save() } }
    @Published var retention: ShelfRetention = .week { didSet { pruneExpired(); save() } }
    @Published var error: String?
    @Published var status = "Drop local files here or choose Add Files."
    @Published private(set) var importing = 0
    private var managedDirectory: URL?
    private var expiration: Task<Void, Never>?
    private var inFlight = Set<URL>()
    private var scopedURLs: [UUID: URL] = [:]
    private let persistState: Bool

    init(managedDirectory suppliedDirectory: URL? = nil, persistState: Bool = true) {
        self.persistState = persistState
        do {
            let directory: URL
            if let suppliedDirectory { directory = suppliedDirectory }
            else { directory = try LocalToolStorage.directory().appendingPathComponent("ShelfFiles", isDirectory: true) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            managedDirectory = directory
            let state = persistState
                ? try LocalToolStorage.load(FileShelfState.self, file: "file-shelf.json", fallback: .init())
                : FileShelfState()
            items = state.items; autoSave = state.autoSave; retention = state.retention
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
            try LocalToolStorage.save(FileShelfState(items: items, autoSave: autoSave, retention: retention), file: "file-shelf.json")
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

    func add(_ url: URL) {
        let host = (url.host ?? "").lowercased()
        guard url.isFileURL, host.isEmpty || host == "localhost", !url.path.isEmpty else {
            error = "The shelf accepts local file URLs only."
            return
        }
        let original = url.standardizedFileURL
        guard items.count + inFlight.count < 200 else { error = "The shelf holds at most 200 entries."; return }
        guard !inFlight.contains(original), !items.contains(where: { $0.originalURL.standardizedFileURL == original }) else {
            status = "This file is already on the shelf."
            return
        }
        guard let directory = managedDirectory else { error = "The local shelf directory is unavailable."; return }
        let copy = autoSave
        inFlight.insert(original); importing += 1
        Task { @MainActor [weak self] in
            // Finish indexing an in-flight copy even if the user changes tools.
            guard let self else { return }
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try FileShelfToolStore.prepare(original, copy: copy, directory: directory)
                }.value
                self.inFlight.remove(original); self.importing -= 1
                self.items.insert(item, at: 0)
                self.error = nil
                self.status = copy ? "Saved a managed copy; the original is unchanged." : "Added a durable reference; the original is unchanged."
                self.save()
            } catch {
                self.inFlight.remove(original); self.importing -= 1
                self.error = "Could not add \(original.lastPathComponent): \(error.localizedDescription)"
            }
        }
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
        guard let managed = item.managedURL else { return }
        guard let directory = managedDirectory else { throw CocoaError(.fileWriteUnknown) }
        let folder = directory.appendingPathComponent(item.id.uuidString, isDirectory: true).standardizedFileURL
        // Only the uniquely owned copy folder can be removed. References and
        // every original URL are excluded, including imported/tampered state.
        guard managed.standardizedFileURL.deletingLastPathComponent() == folder,
              managed.standardizedFileURL != item.originalURL.standardizedFileURL else {
            throw NSError(domain: "NotchOrbitPlus.Shelf", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Refused to delete a path outside this entry's managed copy folder."])
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func remove(_ item: FileShelfItem) {
        do {
            try deleteManagedCopy(item)
            if let url = scopedURLs.removeValue(forKey: item.id) { url.stopAccessingSecurityScopedResource() }
            items.removeAll { $0.id == item.id }
            error = nil; status = "Removed shelf entry; its original file is unchanged."
            save()
        } catch { self.error = "Could not remove shelf entry: \(error.localizedDescription)" }
    }

    func pruneExpired() {
        let expired = items.filter { $0.expired(at: Date(), retention: retention) }
        var failures: [String] = []
        for item in expired {
            do {
                try deleteManagedCopy(item)
                if let url = scopedURLs.removeValue(forKey: item.id) { url.stopAccessingSecurityScopedResource() }
                items.removeAll { $0.id == item.id }
            } catch { failures.append("\(item.originalURL.lastPathComponent): \(error.localizedDescription)") }
        }
        if !expired.isEmpty { save() } else { scheduleExpiration() }
        if !failures.isEmpty { error = "Some expired managed copies could not be removed: " + failures.joined(separator: "; ") }
    }
    private func scheduleExpiration() {
        expiration?.cancel(); expiration = nil
        guard let duration = retention.duration else { return }
        let now = Date()
        // Failed cleanup waits for an explicit retry; do not repeatedly wake
        // for the same expired entry when its filesystem error is unchanged.
        guard let next = items.map({ $0.addedAt.addingTimeInterval(duration) }).filter({ $0 > now }).min() else { return }
        let seconds = max(1, next.timeIntervalSince(now))
        expiration = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.pruneExpired()
        }
    }
    func shutdown() {
        expiration?.cancel(); expiration = nil
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
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
    @ObservedObject private var store = FileShelfToolStore.shared
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Add Files", action: store.addFiles)
                Toggle("Auto-save copies", isOn: $store.autoSave)
                Spacer()
                Picker("Keep", selection: $store.retention) {
                    ForEach(ShelfRetention.allCases) { Text($0.title).tag($0) }
                }.frame(width: 150)
            }
            Text("Drag files into this shelf, then drag them out or share. Retention removes entries and managed copies; originals are never deleted.")
                .font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: store.error)
            List(store.items) { item in
                HStack {
                    Label(item.originalURL.lastPathComponent, systemImage: item.managedURL == nil ? "doc" : "doc.on.doc")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .onDrag {
                            guard let url = store.resolve(item) else { return NSItemProvider() }
                            return NSItemProvider(object: url as NSURL)
                        }
                    Button("Reveal") { store.reveal(item) }.buttonStyle(.borderless)
                    ShelfShareButton(resolve: { store.resolve(item) }).frame(width: 55, height: 24)
                    Button("AirDrop") { store.airDrop(item) }.buttonStyle(.borderless)
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
                Text("\(store.items.count)/200")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding().onAppear { store.pruneExpired() }
    }
}
