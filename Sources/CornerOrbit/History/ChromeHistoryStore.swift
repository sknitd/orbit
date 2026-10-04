import AppKit
import Combine
import CornerCore

@MainActor
final class ChromeHistoryStore: ObservableObject {
    static let shared = ChromeHistoryStore()
    static let privacyExplanation = "Chrome history is optional and local. Choose a History file or profile, then Connect or Refresh explicitly. SQLite opens the history database read-only and may coordinate a live WAL through its transient -shm sidecar. CornerOrbit never edits, clears, copies, checkpoints or uploads browser history. Cached entries stay in memory until disconnect or quit."
    @Published private(set) var entries: [CornerHistoryEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var sourceLabel = "Chrome history not connected"
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isConnected = false
    private let reader: any ChromeHistoryReading
    private let defaults: UserDefaults
    private let ephemeral: Bool
    private var accessRoot: URL?
    private var historyFile: URL?
    private var bookmark: Data?
    private var selectedProfile = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private static let bookmarkKey = "cornerorbit.chromeHistory.bookmark"
    private static let labelKey = "cornerorbit.chromeHistory.label"
    private static let profileKey = "cornerorbit.chromeHistory.isProfile"

    init(reader: any ChromeHistoryReading = ChromeHistoryReader(), defaults: UserDefaults = .standard,
         previewEntries: [CornerHistoryEntry]? = nil) {
        self.reader = reader; self.defaults = defaults; ephemeral = previewEntries != nil
        if let previewEntries {
            entries = CornerHistorySanitizer.sanitize(previewEntries, limit: 100)
            sourceLabel = "Preview Chrome history"
            return
        }
        // Reading our own bookmark preferences does not resolve the bookmark,
        // inspect any profile or start a database read.
        if let saved = defaults.object(forKey: Self.bookmarkKey) {
            guard let saved = saved as? Data, saved.count <= 65_536 else {
                errorMessage = "The saved history connection is unreadable. Choose a file explicitly to replace it, or Disconnect."
                return
            }
            bookmark = saved; selectedProfile = defaults.bool(forKey: Self.profileKey)
            sourceLabel = (defaults.string(forKey: Self.labelKey).map { String($0.prefix(160)) }) ?? "Saved Chrome connection"
            isConnected = true
        }
    }
    deinit { task?.cancel() }

    func chooseHistoryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Connect Read-only"
        panel.message = Self.privacyExplanation + " The usual location is " + ChromeHistoryReader.defaultLocationDescription + "."
        if panel.runModal() == .OK, let url = panel.url { connect(to: url) }
    }
    func chooseProfileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Connect Read-only"
        panel.message = Self.privacyExplanation + " Select a Chrome profile folder containing its History file."
        if panel.runModal() == .OK, let url = panel.url { connectToProfile(url) }
    }
    func connect(to historyFile: URL) { select(historyFile, isProfile: false) }
    func connectToProfile(_ folder: URL) { select(folder, isProfile: true) }
    private func select(_ root: URL, isProfile: Bool) {
        guard root.isFileURL, (root.host ?? "").isEmpty || root.host == "localhost" else { errorMessage = ChromeHistoryError.invalidFile.localizedDescription; return }
        let granted = root.startAccessingSecurityScopedResource()
        defer { if granted { root.stopAccessingSecurityScopedResource() } }
        do {
            let saved = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard saved.count <= 65_536 else { throw ChromeHistoryError.invalidFile }
            generation &+= 1; task?.cancel(); task = nil
            accessRoot = root; historyFile = isProfile ? root.appendingPathComponent("History", isDirectory: false) : root
            selectedProfile = isProfile; bookmark = saved; isConnected = true
            let rawLabel = isProfile ? root.lastPathComponent : root.deletingLastPathComponent().lastPathComponent + " / " + root.lastPathComponent
            sourceLabel = String(rawLabel.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160).map(String.init).joined())
            entries = []; lastRefreshed = nil; errorMessage = nil
            if !ephemeral {
                defaults.set(saved, forKey: Self.bookmarkKey); defaults.set(sourceLabel, forKey: Self.labelKey)
                defaults.set(isProfile, forKey: Self.profileKey)
            }
            refresh()
        } catch { errorMessage = "Could not save access to the chosen history file. Its contents were not read. Choose it again or review macOS file access settings." }
    }
    func refresh() {
        guard isConnected else { errorMessage = "Choose a History file or Chrome profile before refreshing."; return }
        generation &+= 1; let expected = generation
        task?.cancel(); isRefreshing = true; errorMessage = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == expected { self.isRefreshing = false; self.task = nil } }
            var granted = false
            var scoped: URL?
            defer { if granted, let scoped { scoped.stopAccessingSecurityScopedResource() } }
            do {
                let (file, root) = try self.resolveConnection()
                scoped = root; granted = root.startAccessingSecurityScopedResource()
                let loaded = try await self.reader.read(from: file, limit: 100)
                try Task.checkCancellation()
                guard self.generation == expected else { return }
                self.entries = CornerHistorySanitizer.sanitize(loaded, limit: 100)
                self.lastRefreshed = Date(); self.errorMessage = nil
            } catch is CancellationError { }
            catch {
                guard self.generation == expected, !Task.isCancelled else { return }
                self.errorMessage = (error as? ChromeHistoryError)?.localizedDescription
                    ?? "History refresh failed. Previously loaded entries remain available. Choose a readable History file or review macOS file access settings."
            }
        }
    }
    private func resolveConnection() throws -> (URL, URL) {
        if let historyFile, let accessRoot { return (historyFile, accessRoot) }
        guard let bookmark else { throw ChromeHistoryError.invalidFile }
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, root.isFileURL else { throw ChromeHistoryError.invalidFile }
        let file = selectedProfile ? root.appendingPathComponent("History", isDirectory: false) : root
        accessRoot = root; historyFile = file
        return (file, root)
    }
    func disconnect() {
        shutdown(); accessRoot = nil; historyFile = nil; bookmark = nil; selectedProfile = false
        entries = []; lastRefreshed = nil; sourceLabel = "Chrome history not connected"; isConnected = false; errorMessage = nil
        if !ephemeral { for key in [Self.bookmarkKey, Self.labelKey, Self.profileKey] { defaults.removeObject(forKey: key) } }
    }
    func shutdown() { generation &+= 1; task?.cancel(); task = nil; isRefreshing = false }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
}
