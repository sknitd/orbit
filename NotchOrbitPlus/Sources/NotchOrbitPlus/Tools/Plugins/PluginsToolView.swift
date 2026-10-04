import AppKit
import SwiftUI
import NotchCore
import Darwin

struct PlusInstalledPlugin: Codable, Sendable, Identifiable {
    let id: UUID
    let manifest: CorePluginManifest
    var grants: Set<CorePluginPermission>
    var readFolderBookmarks: [Data]
}

@MainActor
final class PlusPluginsStore: ObservableObject {
    static let shared = PlusPluginsStore()
    @Published var enabled = false { didSet { if !enabled { cancel() } } }
    @Published private(set) var plugins: [PlusInstalledPlugin] = []
    @Published private(set) var output: [UUID: CorePluginOutput] = [:]
    @Published private(set) var runningID: UUID?
    @Published private(set) var installing = false
    @Published private(set) var requiresReset = false
    @Published private(set) var message: String?
    private var root: URL?
    private var process: PlusPluginProcess?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(storageDirectory: URL? = nil, loadSaved: Bool = true) {
        // Reading our saved declarations does not run scripts, read clipboard,
        // resolve granted folders, or start network/system integrations.
        do {
            root = try storageDirectory ?? LocalToolStorage.directory().appendingPathComponent("PluginsV1", isDirectory: true)
            if loadSaved, let root, FileManager.default.fileExists(atPath: root.appendingPathComponent("installed.json").path) {
                plugins = try Self.decodeRegistry(PlusPluginFolderIO.readRegistry(root))
            }
        } catch { requiresReset = true; message = "Saved plugin declarations are preserved: \(error.localizedDescription) Reset with a backup before installing." }
    }
    var sandboxAvailable: Bool { PlusPluginSandbox.available }
    var busy: Bool { installing || runningID != nil }
    func openSamples() {
        guard let url = Bundle.main.url(forResource: "Plugins", withExtension: nil) else { message = "Bundled sample plugins are unavailable in this build."; return }
        NSWorkspace.shared.open(url)
    }
    func chooseFolder() {
        guard enabled, !busy, !requiresReset else { return }
        let picker = NSOpenPanel(); picker.title = "Choose a Plugin API v1 folder"; picker.canChooseFiles = false
        picker.canChooseDirectories = true; picker.allowsMultipleSelection = false; picker.prompt = "Install"
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        install(folder)
    }
    func install(_ folder: URL) {
        guard enabled, !busy, !requiresReset else { return }
        let token = UUID(); generation = token; installing = true
        task = Task {
            defer { if generation == token { installing = false; task = nil } }
            do {
                let package = try await loadPackage(folder)
                try Task.checkCancellation()
                guard enabled, generation == token else { return }
                guard !plugins.contains(where: { $0.manifest.id == package.manifest.id }), plugins.count < 20, let root else {
                    throw CorePluginError.invalid("This plugin is already installed, storage is unavailable, or the 20-plugin limit is reached.")
                }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let id = UUID(); let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do {
                    try JSONEncoder().encode(package.manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
                    for (name, data) in package.scripts {
                        let file = destination.appendingPathComponent(name); try data.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                    let next = plugins + [PlusInstalledPlugin(id: id, manifest: package.manifest, grants: [], readFolderBookmarks: [])]
                    try save(next); plugins = next; message = "Installed \(package.manifest.name). Review each requested permission before running a command."
                } catch { try? FileManager.default.removeItem(at: destination); throw error }
            } catch is CancellationError { return }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }
    func grant(_ permission: CorePluginPermission, pluginID: UUID, enabled: Bool) {
        guard self.enabled, !busy, !requiresReset, let index = plugins.firstIndex(where: { $0.id == pluginID }), plugins[index].manifest.permissions.contains(permission) else { return }
        var next = plugins
        if enabled { next[index].grants.insert(permission) } else { next[index].grants.remove(permission); if permission == .selectedFolderRead { next[index].readFolderBookmarks = [] } }
        do { try save(next); plugins = next } catch { message = error.localizedDescription }
    }
    func chooseReadFolder(_ id: UUID) {
        guard enabled, !busy, !requiresReset, let index = plugins.firstIndex(where: { $0.id == id }), plugins[index].grants.contains(.selectedFolderRead), plugins[index].readFolderBookmarks.count < 4 else { return }
        let panel = NSOpenPanel(); panel.title = "Grant this plugin read access to one folder"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard bookmark.count <= 131_072 else { throw CorePluginError.invalid("Folder bookmark is too large.") }
            var next = plugins; next[index].readFolderBookmarks.append(bookmark); try save(next); plugins = next
        } catch { message = error.localizedDescription }
    }
    func remove(_ id: UUID) {
        guard !busy, !requiresReset, let root else { return }
        do {
            let next = plugins.filter { $0.id != id }; try save(next); plugins = next; output[id] = nil
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        } catch { message = error.localizedDescription }
    }
    func run(_ commandID: String, pluginID: UUID) {
        guard enabled, !busy, !requiresReset, sandboxAvailable, let plugin = plugins.first(where: { $0.id == pluginID }),
              let command = plugin.manifest.commands.first(where: { $0.id == commandID }), let root else { return }
        guard plugin.grants == Set(plugin.manifest.permissions) else { message = "Grant the plugin's declared permissions or remove it. Commands do not run with undeclared access."; return }
        let folder = root.appendingPathComponent(plugin.id.uuidString, isDirectory: true)
        let operation = PlusPluginProcess(); process = operation; runningID = plugin.id
        let id = UUID(); generation = id; message = "Running \(plugin.manifest.name)…"
        task = Task {
            var accessed: [URL] = []
            defer { for url in accessed { url.stopAccessingSecurityScopedResource() }; if generation == id { runningID = nil; process = nil; task = nil } }
            do {
                let package = try await loadPackage(folder)
                try Task.checkCancellation(); guard enabled, generation == id else { return }
                guard package.manifest == plugin.manifest, package.scripts[command.script] != nil else {
                    throw CorePluginError.invalid("The installed manifest changed. Remove and reinstall the plugin before running it.")
                }
                var folders: [URL] = []
                for bookmark in plugin.readFolderBookmarks {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                    if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                    guard !stale, url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CorePluginError.invalid("A granted folder is unavailable. Remove and grant the folder again.") }
                    folders.append(url.resolvingSymlinksInPath())
                }
                let clipboard: String?
                if plugin.grants.contains(.clipboardRead) {
                    let board = NSPasteboard.general
                    let hidden = (board.types ?? []).contains {
                        let name = $0.rawValue.lowercased(); return name.contains("concealed") || name.contains("transient") || name.contains("password")
                    }
                    let owner = board.string(forType: .init("org.nspasteboard.source"))?.lowercased() ?? ""
                    let privateOwner = ["1password", "onepassword", "lastpass", "keepass", "bitwarden"].contains(where: owner.contains)
                    clipboard = !hidden && !privateOwner ? board.string(forType: .string).map { String($0.prefix(16_384)) } : nil
                } else { clipboard = nil }
                let bytes = try await operation.run(folder: folder, command: command, grants: plugin.grants, readFolders: folders, clipboard: clipboard)
                try Task.checkCancellation(); guard generation == id else { return }
                output[plugin.id] = try CorePluginOutput.decode(bytes, manifest: plugin.manifest)
                message = "Plugin finished. No clipboard output is applied until you choose Copy Result."
            } catch is CancellationError { if generation == id { message = "Plugin command cancelled." } }
            catch { if generation == id { message = error.localizedDescription } }
        }
    }
    func copyResult(_ id: UUID) {
        guard enabled, let plugin = plugins.first(where: { $0.id == id }), plugin.grants.contains(.clipboardWrite), let text = output[id]?.clipboardText else { return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) { message = "macOS could not copy the plugin result." }
    }
    func cancel() { process?.cancel(); task?.cancel(); generation = UUID(); task = nil; process = nil; installing = false; runningID = nil }
    func shutdown() { enabled = false; cancel(); output = [:] }
    func resetWithBackup() {
        guard requiresReset, !busy, let root else { return }
        do {
            let index = root.appendingPathComponent("installed.json")
            if FileManager.default.fileExists(atPath: index.path) {
                try FileManager.default.copyItem(at: index, to: root.appendingPathComponent("installed-\(UUID().uuidString).backup.json"))
            }
            try Self.publishRegistry(Data("[]".utf8), in: root)
            plugins = []; requiresReset = false; message = "Saved declarations reset. Original registry retained as a backup."
        } catch { message = error.localizedDescription }
    }
    private func loadPackage(_ folder: URL) async throws -> PlusPluginPackage {
        let work = Task.detached { try PlusPluginFolderIO.readPackage(folder) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private static func decodeRegistry(_ data: Data) throws -> [PlusInstalledPlugin] {
        let values = try JSONDecoder().decode([PlusInstalledPlugin].self, from: data)
        guard values.count <= 20, Set(values.map(\.id)).count == values.count else { throw CorePluginError.invalid("Saved plugin identities are invalid.") }
        for plugin in values {
            _ = try CorePluginManifest.decode(JSONEncoder().encode(plugin.manifest))
            guard plugin.grants.isSubset(of: Set(plugin.manifest.permissions)), plugin.readFolderBookmarks.count <= 4,
                  plugin.readFolderBookmarks.allSatisfy({ $0.count <= 131_072 }) else { throw CorePluginError.invalid("Saved plugin grants are invalid.") }
        }
        return values
    }
    private func save(_ values: [PlusInstalledPlugin]) throws {
        guard !requiresReset else { throw CorePluginError.invalid("Reset the preserved unreadable registry with a backup before saving.") }
        guard let root else { throw CorePluginError.invalid("Plugin storage is unavailable.") }
        let index = root.appendingPathComponent("installed.json")
        if FileManager.default.fileExists(atPath: index.path) {
            do { _ = try Self.decodeRegistry(PlusPluginFolderIO.readRegistry(root)) }
            catch { requiresReset = true; throw CorePluginError.invalid("The saved registry became unreadable and is preserved. Reset with a backup before saving.") }
        }
        let data = try JSONEncoder().encode(values); guard data.count <= 4_194_304 else { throw CorePluginError.invalid("Plugin declarations exceed 4 MB.") }
        try Self.publishRegistry(data, in: root)
    }
    private static func publishRegistry(_ data: Data, in root: URL) throws {
        // Complete permissions and writes on a private sibling before rename.
        // After publication, callers can safely publish matching in-memory state.
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directory) }
        let staging = ".installed-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor); Darwin.unlinkat(directory, staging, 0) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Darwin.renameat(directory, staging, directory, "installed.json") == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

@MainActor
struct PluginsToolView: View {
    @ObservedObject private var store: PlusPluginsStore
    init(store: PlusPluginsStore = .shared) { self.store = store }
    @State private var showReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plugin API v1").font(.headline)
            Toggle("Enable plugins for this session", isOn: $store.enabled)
            Text("Install a chosen folder containing manifest.json and declared .sh files. Text, lists, and explicit command buttons are supported. Scripts use shell builtins inside macOS sandbox-exec; network, other runtimes, arbitrary executables, and undeclared files are blocked. Scripts have five seconds and 64 KB of output.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Install Plugin Folder") { store.chooseFolder() }.disabled(!store.enabled || store.busy || store.requiresReset)
            Button("Open Bundled Samples") { store.openSamples() }
            if store.requiresReset { Button("Reset Saved Declarations (Keep Backup)") { showReset = true } }
            if !store.sandboxAvailable { Text("The macOS sandbox runner is unavailable. Script execution is disabled.").font(.caption).foregroundStyle(.orange) }
            ForEach(store.plugins) { plugin in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(plugin.manifest.name).font(.headline); Spacer(); Button("Remove") { store.remove(plugin.id) }.disabled(store.busy || store.requiresReset) }
                    if let description = plugin.manifest.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                    ForEach(plugin.manifest.permissions, id: \.rawValue) { permission in
                        Toggle(permission.title, isOn: Binding(get: { plugin.grants.contains(permission) }, set: { store.grant(permission, pluginID: plugin.id, enabled: $0) })).disabled(!store.enabled || store.busy || store.requiresReset)
                    }
                    if plugin.grants.contains(.selectedFolderRead) {
                        Button("Grant Read Folder (\(plugin.readFolderBookmarks.count)/4)") { store.chooseReadFolder(plugin.id) }.disabled(!store.enabled || plugin.readFolderBookmarks.count >= 4 || store.busy || store.requiresReset)
                    }
                    items(store.output[plugin.id]?.items ?? plugin.manifest.items, plugin: plugin)
                    if store.output[plugin.id]?.clipboardText != nil, plugin.grants.contains(.clipboardWrite) {
                        Button("Copy Result") { store.copyResult(plugin.id) }
                    }
                }.padding(10).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if store.busy { HStack { ProgressView().controlSize(.small); Button("Cancel") { store.cancel() } } }
            if let message = store.message { Text(message).font(.caption).textSelection(.enabled) }
        }.onDisappear { store.cancel() }
            .alert("Reset saved plugin declarations?", isPresented: $showReset) {
                Button("Reset With Backup") { store.resetWithBackup() }; Button("Cancel", role: .cancel) {}
            } message: { Text("The original unreadable registry is copied to a backup. Plugin folders are retained.") }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: { store.cancel() }).frame(width: 0, height: 0))
    }
    @ViewBuilder private func items(_ items: [CorePluginItem], plugin: PlusInstalledPlugin) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item.kind {
            case .text: Text(item.text ?? "").textSelection(.enabled)
            case .list: ForEach(Array((item.values ?? []).enumerated()), id: \.offset) { _, text in Text("• \(text)") }
            case .button: Button(item.title ?? "Run") { if let command = item.commandID { store.run(command, pluginID: plugin.id) } }
                .disabled(!store.enabled || store.busy || store.requiresReset || !store.sandboxAvailable)
            }
        }
    }
}
