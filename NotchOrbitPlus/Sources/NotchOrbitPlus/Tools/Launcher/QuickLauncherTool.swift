import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotchCore

private struct PlusLauncherTargetCheck: Sendable {
    let id: UUID
    let resolution: PlusLauncherResolution?
    let error: String?
}

@MainActor
final class PlusLauncherStore: ObservableObject {
    static let shared = PlusLauncherStore()
    static let defaultsKey = "plus.launcher.pins.v1"
    @Published private(set) var pins: [PlusLauncherPin] = []
    @Published var search = ""
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var targetErrors: [UUID: String] = [:]
    @Published private(set) var icons: [UUID: NSImage] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var unreadableSavedData = false

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        do { pins = try PlusLauncherPins.decode(data) }
        catch {
            unreadableSavedData = true
            status = "Saved launcher pins could not be read: \(error.localizedDescription) Reset saved pins to add new targets."
        }
        // Loading saved references never opens their targets or runs Shortcuts.
    }
    var filteredPins: [PlusLauncherPin] { pins.filter { PlusLauncherPins.matches($0, query: search) } }
    var needsReset: Bool { unreadableSavedData }

    func choose(_ kind: PlusLauncherKind) {
        guard !busy, !unreadableSavedData, kind != .shortcut else { return }
        let panel = NSOpenPanel()
        panel.title = kind == .application ? "Pin an application" : "Pin a folder"
        panel.prompt = "Pin"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind == .application
        panel.treatsFilePackagesAsDirectories = false
        if kind == .application { panel.allowedContentTypes = [.applicationBundle] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let pin = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try PlusLauncherBookmarks.makePin(at: url, kind: kind)
            }.value
            try Task.checkCancellation()
            try self.save(PlusLauncherPins.inserting(pin, into: self.pins))
            self.status = "Pinned \(pin.label)."
            self.refreshTargetsAfterOperation()
        }
    }

    func pinShortcut(_ choice: OrbitShortcutChoice) {
        guard !busy, !unreadableSavedData else { return }
        do {
            let pin = PlusLauncherPin(label: choice.name, kind: .shortcut, targetIdentifier: choice.id)
            try save(PlusLauncherPins.inserting(pin, into: pins))
            status = "Pinned \(choice.name)."
        } catch { status = error.localizedDescription }
    }

    func launch(_ pin: PlusLauncherPin) {
        guard !busy, pins.contains(where: { $0.id == pin.id }) else { return }
        if pin.kind == .shortcut {
            guard !PlusShortcutsStore.shared.busy else { status = "Wait for the current Shortcuts command or cancel it first."; return }
            PlusShortcutsStore.shared.run(identifier: pin.targetIdentifier)
            return
        }
        perform {
            let resolution = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try PlusLauncherBookmarks.resolve(pin)
            }.value
            try Task.checkCancellation()
            try self.apply(resolution, for: pin.id)
            let url = resolution.url
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if pin.kind == .application {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            } else if !NSWorkspace.shared.open(url) {
                throw NSError(domain: "NotchOrbitPlus.Launcher", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Finder could not open this folder."])
            }
            self.targetErrors[pin.id] = nil
            self.status = "Opened \(pin.label)."
        }
    }

    func rename(_ id: UUID, to label: String) {
        guard !busy, let index = pins.firstIndex(where: { $0.id == id }) else { return }
        var next = pins
        next[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try PlusLauncherPins.validate(next[index]); try save(next); status = "Pin renamed." }
        catch { status = error.localizedDescription }
    }
    func unpin(_ id: UUID) {
        guard !busy else { return }
        do {
            try save(pins.filter { $0.id != id }); icons[id] = nil; targetErrors[id] = nil
            status = "Removed the pin. Its original target is unchanged."
        } catch { status = error.localizedDescription }
    }
    func move(_ id: UUID, by delta: Int) {
        guard !busy else { return }
        do { try save(PlusLauncherPins.moved(pins, id: id, by: delta)) }
        catch { status = error.localizedDescription }
    }
    func resetUnreadablePins() {
        guard unreadableSavedData else { return }
        do {
            try save([]); unreadableSavedData = false; status = "Saved pins reset. Choose targets to pin."
        } catch { status = error.localizedDescription }
    }

    func refreshTargets() {
        guard !busy, !unreadableSavedData else { return }
        let targets = pins.filter { $0.kind != .shortcut }
        guard !targets.isEmpty else { return }
        perform {
            let checks = await Task.detached(priority: .utility) {
                targets.map { pin -> PlusLauncherTargetCheck in
                    do {
                        try Task.checkCancellation()
                        return PlusLauncherTargetCheck(id: pin.id, resolution: try PlusLauncherBookmarks.resolve(pin), error: nil)
                    } catch { return PlusLauncherTargetCheck(id: pin.id, resolution: nil, error: error.localizedDescription) }
                }
            }.value
            try Task.checkCancellation()
            for check in checks {
                self.targetErrors[check.id] = check.error
                if let resolution = check.resolution {
                    try self.apply(resolution, for: check.id)
                    let accessing = resolution.url.startAccessingSecurityScopedResource()
                    self.icons[check.id] = NSWorkspace.shared.icon(forFile: resolution.url.path)
                    if accessing { resolution.url.stopAccessingSecurityScopedResource() }
                } else { self.icons[check.id] = nil }
            }
        }
    }

    private func apply(_ resolution: PlusLauncherResolution, for id: UUID) throws {
        guard let index = pins.firstIndex(where: { $0.id == id }),
              resolution.refreshedBookmark != nil || pins[index].targetIdentifier != resolution.url.path else { return }
        var next = pins
        next[index].targetIdentifier = resolution.url.path
        if let bookmark = resolution.refreshedBookmark { next[index].bookmark = bookmark }
        try save(next)
    }
    private func save(_ next: [PlusLauncherPin]) throws {
        let data = try PlusLauncherPins.encode(next)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        pins = next
    }
    private func refreshTargetsAfterOperation() {
        // `perform` clears its busy state before this queued explicit-pin refresh.
        Task { await Task.yield(); self.refreshTargets() }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let id = UUID(); generation = id; busy = true
        task = Task {
            defer { if self.generation == id { self.busy = false; self.task = nil } }
            do { try await operation() }
            catch is CancellationError { self.status = "Launcher operation cancelled." }
            catch { self.status = error.localizedDescription }
        }
    }
}

@MainActor
struct QuickLauncherToolView: View {
    @StateObject private var model = PlusLauncherStore.shared
    @StateObject private var shortcuts = PlusShortcutsStore.shared
    @State private var shortcutID = ""
    @State private var showShortcuts = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Launcher").font(.headline)
            Text("Pin applications, folders, and favorite Shortcuts. Only the Launch button opens or runs a target.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Pin app") { model.choose(.application) }
                Button("Pin folder") { model.choose(.folder) }
                Button("Refresh targets", action: model.refreshTargets)
            }.disabled(model.busy || model.needsReset)
            DisclosureGroup("Favorite Shortcuts", isExpanded: $showShortcuts) {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Load / Refresh Shortcuts", action: shortcuts.load).disabled(shortcuts.busy)
                    if !shortcuts.choices.isEmpty {
                        Picker("Shortcut", selection: $shortcutID) {
                            Text("Choose a shortcut").tag("")
                            ForEach(shortcuts.choices) { Text($0.name).tag($0.id) }
                        }
                        Button("Pin selected shortcut") {
                            if let choice = shortcuts.choices.first(where: { $0.id == shortcutID }) { model.pinShortcut(choice) }
                        }.disabled(shortcutID.isEmpty || shortcuts.busy || model.busy || model.needsReset)
                    }
                    Text("Loading lists names and identifiers. Select a shortcut and pin it; Launch runs its actions.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }
            if !model.pins.isEmpty {
                TextField("Search pinned targets", text: $model.search)
                ForEach(model.filteredPins) { pin in
                    HStack(alignment: .top, spacing: 8) {
                        if let icon = model.icons[pin.id] {
                            Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                        } else { Image(systemName: symbol(pin.kind)).frame(width: 28, height: 28) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pin.label).lineLimit(2)
                            Text(pin.kind == .shortcut ? "Shortcut" : pin.targetIdentifier)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let error = model.targetErrors[pin.id] {
                                Text("Unavailable: \(error)").font(.caption).foregroundStyle(.orange)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Launch") { model.launch(pin) }.disabled(model.busy || (pin.kind == .shortcut && shortcuts.busy))
                        Menu {
                            Button("Rename") { renameID = pin.id; renameText = pin.label; showRename = true }
                            Button("Move up") { model.move(pin.id, by: -1) }.disabled(model.pins.first?.id == pin.id)
                            Button("Move down") { model.move(pin.id, by: 1) }.disabled(model.pins.last?.id == pin.id)
                            Button("Unpin", role: .destructive) { model.unpin(pin.id) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    }.padding(.vertical, 4)
                }
                if model.filteredPins.isEmpty { Text("No pinned targets match this search.").foregroundStyle(.secondary) }
            } else if !model.needsReset { Text("Choose an app, folder, or shortcut to add your first pin.").foregroundStyle(.secondary) }
            if model.busy { ProgressView().controlSize(.small) }
            if let status = model.status { Text(status).font(.caption).textSelection(.enabled) }
            if model.needsReset { Button("Reset unreadable saved pins", role: .destructive) { showReset = true } }
            if shortcuts.busy {
                HStack { ProgressView().controlSize(.small); Button("Cancel Shortcuts command", action: shortcuts.cancel) }
            }
            if showShortcuts || shortcuts.busy || model.pins.contains(where: { $0.kind == .shortcut }) {
                Text(shortcuts.message).font(.caption).textSelection(.enabled)
            }
        }
        .alert("Rename pin", isPresented: $showRename) {
            TextField("Label", text: $renameText)
            Button("Save") { if let id = renameID { model.rename(id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reset saved launcher pins?", isPresented: $showReset) {
            Button("Reset pins", role: .destructive, action: model.resetUnreadablePins)
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes only the unreadable saved pin list. It does not change applications, folders, or Shortcuts.") }
        .onAppear(perform: model.refreshTargets)
    }
    private func symbol(_ kind: PlusLauncherKind) -> String {
        switch kind { case .application: "app"; case .folder: "folder"; case .shortcut: "square.stack.3d.up" }
    }
}
