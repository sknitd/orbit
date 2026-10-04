import AppKit
import SwiftUI
import NotchCore

@MainActor final class OrbitInboxStore: ObservableObject {
    static let shared = OrbitInboxStore()
    private static let bookmarkKey = "plus.orbitInbox.folder-bookmark"
    private static let enabledKey = "plus.orbitInbox.enabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var folderName = "Choose iCloud Drive / Orbit Inbox"
    @Published private(set) var isSending = false
    @Published private(set) var status = "Off. Select the folder explicitly; open the same folder in Files on iPhone."
    @Published private(set) var error: String?
    @Published private(set) var lastWrittenURL: URL?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; enabled = defaults.bool(forKey: Self.enabledKey) }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose an Orbit Inbox folder in iCloud Drive. Your iCloud setup handles delivery; this app verifies only the local write. Open that folder in Files on iPhone."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try configureFolder(folder) } catch { self.error = error.localizedDescription }
    }
    func configureFolder(_ folder: URL) throws {
        guard folder.isFileURL, try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoPermission) }
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey); folderName = folder.lastPathComponent; error = nil
        status = "Folder selected. Enable Inbox and explicitly send a file or note."
    }
    func setEnabled(_ value: Bool) {
        if value && defaults.data(forKey: Self.bookmarkKey) == nil { error = "Choose the shared Inbox folder first."; return }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        if !value { shutdown(); status = "Off. Existing Inbox copies are retained." }
    }
    func sendFileFromShelf(_ item: FileShelfItem, shelf: FileShelfToolStore) {
        guard let url = shelf.resolve(item) else { error = shelf.error; return }; sendFile(url)
    }
    func sendFile(_ source: URL) { start { folder in try Self.writeFile(source, to: folder) } }
    func sendNote(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 200_000 else { error = "Send a note of 1–200 KB. Its local original is unchanged."; return }
        let data = Data(text.utf8)
        start { folder in try Self.writeNote(data, to: folder) }
    }
    private func start(_ write: @escaping @Sendable (URL) throws -> URL) {
        guard enabled, !isSending else { error = enabled ? "Wait for the current local write." : "Enable Orbit Inbox in Shelves & Rules first."; return }
        do {
            guard let bookmark = try PlusPortableDefaults.data(Self.bookmarkKey, in: defaults) else { throw SyncFailure.invalid("Choose an Inbox folder first.") }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw SyncFailure.invalid("Inbox access is stale. Choose the folder again explicitly.") }
            let ticket = UUID(); generation = ticket; isSending = true; error = nil
            task = Task { @MainActor [weak self] in
                let granted = folder.startAccessingSecurityScopedResource(); defer { if granted { folder.stopAccessingSecurityScopedResource() } }
                defer { if self?.generation == ticket { self?.isSending = false; self?.task = nil } }
                do {
                    let child = Task.detached(priority: .utility) { try write(folder) }
                    let output = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
                    guard let self else { return }
                    // Publication may have finished before cancellation; retain the unique user copy and report that local fact.
                    self.lastWrittenURL = output
                    self.status = "Wrote \(output.lastPathComponent) locally. iCloud upload and iPhone delivery are not verified."
                } catch is CancellationError { self?.status = "Cancelled before publication; originals are unchanged." }
                catch { self?.error = "Inbox local write failed: \(error.localizedDescription)" }
            }
        } catch { self.error = "Inbox access failed; no delivery is assumed: \(error.localizedDescription)" }
    }
    nonisolated static func writeFile(_ source: URL, to folder: URL) throws -> URL {
        guard source.isFileURL, source.host == nil || source.host == "" || source.host == "localhost" else { throw CocoaError(.fileReadCorruptFile) }
        let granted = source.startAccessingSecurityScopedResource(); defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= 100 * 1024 * 1024 else { throw SyncFailure.invalid("Inbox accepts regular files up to 100 MB, excluding links and folders.") }
        let suffix = source.pathExtension.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) && source.pathExtension.count <= 20 ? source.pathExtension : ""
        return try coordinatedWrite(folder) { destination in
            try OutputTransaction.write(source: source, outputDirectory: destination, stem: uniqueStem("Orbit-file"), extension: suffix,
                writer: { try FileManager.default.copyItem(at: source, to: $0) },
                validate: { url in guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { throw CocoaError(.fileReadCorruptFile) } })
        }
    }
    nonisolated static func writeNote(_ bytes: Data, to folder: URL) throws -> URL {
        guard !bytes.isEmpty, bytes.count <= 200_000, String(data: bytes, encoding: .utf8) != nil else { throw SyncFailure.invalid("Inbox notes require valid UTF-8 of 1–200 KB.") }
        return try coordinatedWrite(folder) { destination in
            try OutputTransaction.write(source: destination, outputDirectory: destination, stem: uniqueStem("Orbit-note"), extension: "txt",
                writer: { try bytes.write(to: $0) }, validate: { url in guard try Data(contentsOf: url) == bytes else { throw CocoaError(.fileReadCorruptFile) } })
        }
    }
    nonisolated private static func uniqueStem(_ prefix: String) -> String { "\(prefix)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)" }
    nonisolated private static func coordinatedWrite(_ folder: URL, writer: (URL) throws -> URL) throws -> URL {
        var coordinatorError: NSError?, result: Result<URL, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: [], error: &coordinatorError) { coordinated in result = Result { try writer(coordinated) } }
        if let coordinatorError { throw coordinatorError }; guard let result else { throw CocoaError(.fileWriteUnknown) }; return try result.get()
    }
    func shutdown() { task?.cancel(); task = nil }
}

@MainActor struct OrbitInboxSettingsView: View {
    @ObservedObject private var store: OrbitInboxStore
    @State private var note = ""
    init(store: OrbitInboxStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Button("Choose iCloud Inbox Folder…") { store.chooseFolder() }; Text(store.folderName).font(.caption).foregroundStyle(.secondary) }
            Toggle("Enable explicit Orbit Inbox sends", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
            TextField("Note to send as a new text file", text: $note).textFieldStyle(.roundedBorder)
            HStack { Button("Send This Note") { store.sendNote(note) }.disabled(note.isEmpty || !store.enabled || store.isSending); if store.isSending { ProgressView().controlSize(.small) } }
            Text(store.status).font(.caption).foregroundStyle(.secondary); LocalToolError(message: store.error)
            Text("In File Shelf, use iPhone to send an explicit unique file copy. Open Orbit Inbox in the iPhone Files app. This does not use Handoff APIs or prove cloud completion; folder access, account setup and delivery belong to your provider.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
