import AppKit
import Combine
import NotchCore

extension Notification.Name {
    static let plusSyncWillReadLocal = Notification.Name("NotchOrbitPlus.Sync.WillReadLocal")
    static let plusSyncLocalDidChange = Notification.Name("NotchOrbitPlus.Sync.LocalDidChange")
}

@MainActor
final class PlusSyncService: ObservableObject {
    static let shared = PlusSyncService()
    @Published private(set) var enabled: Bool
    @Published private(set) var folderName = "No shared folder selected"
    @Published private(set) var status = "Sync is off. Notes and tasks stay on this Mac."
    @Published private(set) var error: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var state: SyncSnapshot
    private var folder: URL?
    private var scoped = false
    private var timer: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var portableTask: Task<Void, Never>?
    private var generation = UUID()
    private var applyingRemote = false
    private var unsavedLocal = false
    private var ledgerUnreadable = false
    private var readSettings: (@MainActor () throws -> SyncSharedSettings)?
    private var applySettings: (@MainActor (SyncSharedSettings) throws -> Void)?
    private var validateSettings: (@MainActor (SyncSharedSettings) throws -> Void)?
    private let defaults = UserDefaults.standard
    private let enabledKey = "plus.sync.enabled"
    private let bookmarkKey = "plus.sync.folder.bookmark"
    private let deviceKey = "plus.sync.device-id"
    private var ledgerURL: URL { get throws { try LocalToolStorage.directory().appendingPathComponent("sync-state-v1.json") } }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "plus.sync.enabled")
        let identity = defaults.string(forKey: "plus.sync.device-id").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identity.uuidString, forKey: "plus.sync.device-id")
        state = SyncSnapshot(deviceID: identity)
        do {
            let url = try LocalToolStorage.directory().appendingPathComponent("sync-state-v1.json")
            if try PlusSyncFolderIO.hasNode(url) {
                let stored = try SyncSnapshot.decode(PlusSyncFolderIO.boundedData(url, limit: SyncSnapshot.maximumBytes))
                state = try SyncMerge.threeWay(base: state, local: state, remote: stored)
            }
        } catch {
            ledgerUnreadable = true
            self.error = "Local sync metadata could not be read. Its original and your local notes/tasks are preserved. Reset metadata with a backup before enabling sync."
        }
    }
    func configureSettings(read: @escaping @MainActor () throws -> SyncSharedSettings,
                           apply: @escaping @MainActor (SyncSharedSettings) throws -> Void,
                           validate: (@MainActor (SyncSharedSettings) throws -> Void)? = nil) {
        readSettings = read; applySettings = apply; validateSettings = validate
    }
    /// Call on launch. This does not access a shared folder unless the user previously enabled sync.
    func start() {
        guard enabled, !ledgerUnreadable else { return }
        shutdown()
        do {
            guard let bookmark = defaults.data(forKey: bookmarkKey) else { throw SyncFailure.invalid("Choose a shared folder before enabling sync.") }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            scoped = url.startAccessingSecurityScopedResource(); folder = url; folderName = url.lastPathComponent
            if stale { defaults.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey) }
            status = "Sync enabled. Shared-folder delivery is handled by your provider."
            syncNow()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.syncNow()
                }
            }
        } catch { self.error = "Could not access the shared folder: \(error.localizedDescription)" }
    }
    func shutdown() {
        generation = UUID(); timer?.cancel(); timer = nil; syncTask?.cancel(); syncTask = nil
        settingsTask?.cancel(); settingsTask = nil; portableTask?.cancel(); portableTask = nil; isSyncing = false
        if scoped, let folder { folder.stopAccessingSecurityScopedResource() }
        scoped = false; folder = nil
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the same iCloud Drive, Dropbox or network folder on each Mac. Only notes, tasks and the listed preferences are shared when you enable sync."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            shutdown(); defaults.set(bookmark, forKey: bookmarkKey); folderName = url.lastPathComponent; error = nil
            if enabled { start() }
        } catch { self.error = "Could not retain folder access: \(error.localizedDescription)" }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value && ledgerUnreadable { error = "Reset unreadable metadata with a backup before enabling sync."; return }
        if value && defaults.data(forKey: bookmarkKey) == nil { error = "Choose a shared folder first."; return }
        enabled = value; defaults.set(value, forKey: enabledKey)
        if value { start() } else { shutdown(); status = "Sync is off. Shared snapshots stay in the folder; local notes and tasks are retained." }
    }
    /// Root preferences publish before didSet; debounce ensures the read closure sees the new value.
    func settingsDidChange() {
        guard enabled, !applyingRemote else { return }
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.captureConfiguredSettings()
        }
    }
    func noteDidSave(_ text: String) {
        guard enabled, !applyingRemote, !ledgerUnreadable else { return }
        mutate { try $0.captureNote(text) }
    }
    func tasksDidSave(_ items: [ToDoItem]) {
        guard enabled, !applyingRemote, !ledgerUnreadable else { return }
        mutate { try $0.captureTasks(items) }
    }
    func portableDidChange() {
        guard enabled, !applyingRemote, !ledgerUnreadable else { return }
        portableTask?.cancel()
        portableTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            mutate { try $0.capturePortable(readPortableLibrary()) }
        }
    }
    private func readPortableLibrary() throws -> SyncPortableLibrary {
        let value = SyncPortableLibrary(launcherPins: try PlusLauncherStore.shared.exportSyncedPins(),
            workflows: try WorkflowStore.shared.exportSyncedPresets(), palettes: try CoreColorPaletteLibrary.decode(ColorPickerStore.shared.exportData()))
        try value.validate(); return value
    }
    private func validatePortableApply(_ snapshot: SyncSnapshot) throws {
        if let values = snapshot.launcherPins.preferred(on: snapshot.deviceID) { try PlusLauncherStore.shared.validateSyncedPins(values) }
        if let values = snapshot.workflows.preferred(on: snapshot.deviceID) { try WorkflowStore.shared.validateSyncedPresets(values) }
        if let values = snapshot.palettes.preferred(on: snapshot.deviceID) { try ColorPickerStore.shared.validateSyncImport(values.encoded()) }
    }
    private func applyPortable(_ snapshot: SyncSnapshot) throws {
        if let values = snapshot.launcherPins.preferred(on: snapshot.deviceID) { try PlusLauncherStore.shared.applySyncedPins(values) }
        if let values = snapshot.workflows.preferred(on: snapshot.deviceID) { try WorkflowStore.shared.applySyncedPresets(values) }
        if let values = snapshot.palettes.preferred(on: snapshot.deviceID) { try ColorPickerStore.shared.applySyncedData(values.encoded()) }
    }
    func reportUnsavedLocalChanges() { if enabled { unsavedLocal = true } }
    private func mutate(_ change: (inout SyncSnapshot) throws -> Void) {
        do {
            var next = state; try change(&next); try persist(next); state = next
        } catch { self.error = "Could not record local sync changes: \(error.localizedDescription)"; unsavedLocal = true }
    }
    private func captureConfiguredSettings() {
        guard let readSettings, !applyingRemote else { return }
        mutate { try $0.captureSettings(readSettings()) }
    }
    private func persist(_ snapshot: SyncSnapshot, replacingUnreadableAfterBackup: Bool = false) throws {
        let url = try ledgerURL
        if !replacingUnreadableAfterBackup, try PlusSyncFolderIO.hasNode(url) {
            _ = try SyncSnapshot.decode(PlusSyncFolderIO.boundedData(url, limit: SyncSnapshot.maximumBytes))
        }
        try snapshot.encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func captureLocalFiles() throws {
        let directory = try LocalToolStorage.directory()
        var next = state
        let note = directory.appendingPathComponent("quick-note.txt")
        if try PlusSyncFolderIO.hasNode(note) {
            guard let text = String(data: try PlusSyncFolderIO.boundedData(note, limit: 200_000), encoding: .utf8) else { throw SyncFailure.invalid("The local note is not valid UTF-8; it was not replaced.") }
            try next.captureNote(text)
        }
        let tasks = directory.appendingPathComponent("todos.json")
        if try PlusSyncFolderIO.hasNode(tasks) {
            let values = try JSONDecoder().decode([ToDoItem].self, from: PlusSyncFolderIO.boundedData(tasks, limit: 4 * 1024 * 1024))
            try next.captureTasks(values)
        }
        if let readSettings { try next.captureSettings(readSettings()) }
        try next.capturePortable(readPortableLibrary())
        try persist(next); state = next
    }
    func syncNow() {
        guard enabled, !ledgerUnreadable, !isSyncing, let folder else { return }
        unsavedLocal = false
        NotificationCenter.default.post(name: .plusSyncWillReadLocal, object: nil)
        guard !unsavedLocal else { error = "Unsaved local edits could not be flushed. Sync paused so they cannot be overwritten."; return }
        settingsTask?.cancel(); settingsTask = nil; portableTask?.cancel(); portableTask = nil
        do { try captureLocalFiles() } catch { self.error = "Sync paused; local originals are preserved: \(error.localizedDescription)"; return }
        let base = state, ticket = generation
        isSyncing = true; error = nil; status = "Reading shared snapshots…"
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == ticket { isSyncing = false } }
            do {
                let reading = Task.detached(priority: .utility) { try PlusSyncFolderIO.read(folder: folder) }
                let peers = try await withTaskCancellationHandler(operation: { try await reading.value }, onCancel: { reading.cancel() })
                try Task.checkCancellation(); guard ticket == generation else { return }
                var remote = base
                for peer in peers { remote = try SyncMerge.threeWay(base: base, local: remote, remote: peer) }
                let next = try SyncMerge.threeWay(base: base, local: state, remote: remote)
                let applied = try applyLocally(next)
                status = "Writing this Mac’s coordinated snapshot…"
                let publishing = Task.detached(priority: .utility) { try PlusSyncFolderIO.publish(applied, folder: folder) }
                let published = try await withTaskCancellationHandler(operation: { try await publishing.value }, onCancel: { publishing.cancel() })
                try Task.checkCancellation(); guard ticket == generation else { return }
                let final = try SyncMerge.threeWay(base: applied, local: state, remote: published)
                try applyLocally(final)
                lastSyncAt = Date()
                status = "Saved to the shared folder; read \(peers.count) snapshot(s). Provider upload and delivery to another Mac are not verified."
            } catch is CancellationError {} catch { if generation == ticket { self.error = "Sync could not finish: \(error.localizedDescription)"; status = "Local originals retained. Retry when the shared folder is available." } }
        }
    }
    @discardableResult
    private func applyLocally(_ next: SyncSnapshot) throws -> SyncSnapshot {
        // Flush any edits made while coordinated reads were pending before choosing the final local state.
        unsavedLocal = false
        NotificationCenter.default.post(name: .plusSyncWillReadLocal, object: nil)
        guard !unsavedLocal else { throw SyncFailure.invalid("Local drafts could not be saved; incoming data was not applied.") }
        // Revalidate/capture files changed while shared-folder coordination was pending.
        try captureLocalFiles()
        let merged = try SyncMerge.threeWay(base: state, local: state, remote: next)
        try validatePortableApply(merged)
        if let settings = merged.settings.preferred(on: merged.deviceID) { try validateSettings?(settings) }
        try LocalToolStorage.applySyncState(merged)
        applyingRemote = true
        do {
            try applyPortable(merged)
            if let settings = merged.settings.preferred(on: merged.deviceID) { try applySettings?(settings) }
        } catch { applyingRemote = false; throw error }
        state = merged
        applyingRemote = false
        NotificationCenter.default.post(name: .plusSyncLocalDidChange, object: nil)
        return merged
    }
    func resolveNote(_ revisionID: UUID) {
        guard let revision = state.note.revisions.first(where: { $0.id == revisionID }) else { return }
        do {
            try flushBeforeResolution()
            try backupConflicts()
            var next = state; try next.captureNote(revision.value, resolve: true)
            try applyLocally(next); syncNow()
        } catch { self.error = "Could not resolve note conflict; variants retained: \(error.localizedDescription)" }
    }
    func resolveSettings(_ revisionID: UUID) {
        guard let revision = state.settings.revisions.first(where: { $0.id == revisionID }) else { return }
        do {
            try flushBeforeResolution()
            try backupConflicts()
            var next = state; try next.captureSettings(revision.value, resolve: true)
            try applyLocally(next); syncNow()
        } catch { self.error = "Could not resolve settings conflict; variants retained: \(error.localizedDescription)" }
    }
    func resolvePortable(_ section: SyncPortableSection, revisionID: UUID) {
        do {
            try flushBeforeResolution(); try backupConflicts()
            var library = state.portableLibrary()
            switch section {
            case .launcher:
                guard let value = state.launcherPins.revisions.first(where: { $0.id == revisionID })?.value else { return }; library.launcherPins = value
            case .workflows:
                guard let value = state.workflows.revisions.first(where: { $0.id == revisionID })?.value else { return }; library.workflows = value
            case .palettes:
                guard let value = state.palettes.revisions.first(where: { $0.id == revisionID })?.value else { return }; library.palettes = value
            }
            var next = state; try next.capturePortable(library, resolve: section)
            try applyLocally(next); syncNow()
        } catch { self.error = "Could not resolve portable library conflict; variants retained: \(error.localizedDescription)" }
    }
    private func flushBeforeResolution() throws {
        unsavedLocal = false
        NotificationCenter.default.post(name: .plusSyncWillReadLocal, object: nil)
        guard !unsavedLocal else { throw SyncFailure.invalid("Local drafts could not be saved; conflict variants were retained.") }
        try captureLocalFiles()
    }
    private func backupConflicts() throws {
        let directory = try LocalToolStorage.directory().appendingPathComponent("SyncConflictBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = directory.appendingPathComponent("conflicts-\(UUID().uuidString).json")
        try state.encoded().write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    func resetMetadataPreservingBackup() {
        setEnabled(false)
        do {
            let url = try ledgerURL
            if try PlusSyncFolderIO.hasNode(url) {
                let backup = url.deletingLastPathComponent().appendingPathComponent("sync-state-\(UUID().uuidString).backup.json")
                try FileManager.default.copyItem(at: url, to: backup)
                if try backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
            let identity = UUID(), fresh = SyncSnapshot(deviceID: identity)
            try persist(fresh, replacingUnreadableAfterBackup: true)
            defaults.set(identity.uuidString, forKey: deviceKey); state = fresh; ledgerUnreadable = false; error = nil
            status = "Metadata reset with a backup. Legacy notes/tasks and shared files are unchanged. Enable sync to merge again."
        } catch { self.error = "Could not preserve/reset metadata: \(error.localizedDescription)" }
    }
}
