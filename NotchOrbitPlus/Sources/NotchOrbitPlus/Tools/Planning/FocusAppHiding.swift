import AppKit
import SwiftUI
import Combine
import NotchCore
import UniformTypeIdentifiers

@MainActor
final class FocusAppHidingStore: ObservableObject {
    static let shared = FocusAppHidingStore()
    static let recoveryKey = "plus.focus.app-hiding.owned.v1"
    static let defaultsKey = "plus.focus.app-hiding.v1"
    @Published private(set) var configuration = FocusAppConfiguration()
    @Published private(set) var preview: [FocusAppSnapshot] = []
    @Published private(set) var hiddenCount = 0
    @Published private(set) var error: String?
    private var owned: [FocusAppSnapshot] = []
    private var active = false
    private var blocked = false
    private var subscription: AnyCancellable?
    private let defaults: UserDefaults
    private let snapshots: @MainActor () -> [FocusAppSnapshot]
    private let hideApp: @MainActor (Int32) -> Bool
    private let unhideApp: @MainActor (Int32) -> Bool
    private let ownProcessID: Int32

    init(defaults: UserDefaults = .standard, ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
         snapshots: @escaping @MainActor () -> [FocusAppSnapshot] = {
             NSWorkspace.shared.runningApplications.compactMap { app in
                 app.bundleIdentifier.map { FocusAppSnapshot(processID: app.processIdentifier, bundleID: $0, hidden: app.isHidden, launchDate: app.launchDate) }
             }
         }, hide: @escaping @MainActor (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.hide() == true },
         unhide: @escaping @MainActor (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.unhide() == true }) {
        self.defaults = defaults; self.ownProcessID = ownProcessID
        self.snapshots = snapshots; hideApp = hide; unhideApp = unhide
        do { if let data = try PlusPortableDefaults.data(Self.defaultsKey, in: defaults) { configuration = try FocusAppConfiguration.decode(data) } }
        catch { blocked = true; self.error = "Stored focus app choices are unreadable and preserved. Reset with a backup before changing them." }
        do {
            if let data = try PlusPortableDefaults.data(Self.recoveryKey, in: defaults) {
                guard data.count <= 32_768 else { throw SyncFailure.invalid("Focus recovery state exceeds its bound.") }
                let saved = try JSONDecoder().decode([FocusAppSnapshot].self, from: data)
                guard saved.count <= 32, saved.allSatisfy({ $0.processID > 0 && $0.launchDate?.timeIntervalSince1970.isFinite == true }) else {
                    throw SyncFailure.invalid("Focus recovery state contains invalid process identities.")
                }
                try FocusAppConfiguration(bundleIDs: Array(Set(saved.map(\.bundleID)))).validate()
                owned = saved; hiddenCount = saved.count
            }
        } catch { blocked = true; self.error = "Stored focus recovery is unreadable and preserved. Reset with a backup to change focus hiding." }
    }
    func start() {
        restore()

        guard subscription == nil else { return }
        subscription = FocusTimerService.shared.$timer.sink { [weak self] value in
            Task { @MainActor [weak self] in self?.update(timer: value) }
        }
    }
    func refreshPreview() {
        preview = FocusAppPolicy.hideCandidates(configuration: .init(enabled: true, bundleIDs: configuration.bundleIDs),
            running: snapshots(), ownProcessID: ownProcessID)
    }
    func setEnabled(_ value: Bool) {
        guard !blocked else { return }
        var next = configuration; next.enabled = value
        save(next); if !value { restore(); active = false }
    }
    func chooseApp() {
        guard !blocked else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.title = "Choose applications to hide during focus"; panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var next = configuration
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { error = "An application has no readable bundle identifier."; return }
            if !next.bundleIDs.contains(id) { next.bundleIDs.append(id) }
        }
        save(next); refreshPreview()
    }
    func remove(_ id: String) {
        var next = configuration; next.bundleIDs.removeAll { $0 == id }; save(next); refreshPreview()
    }
    func setConfiguration(_ value: FocusAppConfiguration) { save(value); if !configuration.enabled { restore(); active = false } }
    private func save(_ value: FocusAppConfiguration) {
        guard !blocked else { return }
        do { try value.validate(); defaults.set(try JSONEncoder().encode(value), forKey: Self.defaultsKey); configuration = value; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func update(timer: FocusTimer, at date: Date = Date()) {
        let wantsHide = configuration.enabled && !blocked && timer.phase == .focus && timer.isRunning && timer.remaining(at: date) > 0
        if !wantsHide { if active || !owned.isEmpty { restore() }; active = false; return }
        guard !active else { return }
        active = true
        let candidates = FocusAppPolicy.hideCandidates(configuration: configuration, running: snapshots(), ownProcessID: ownProcessID)
        for candidate in candidates {
            guard !owned.contains(where: { $0.processID == candidate.processID && $0.bundleID == candidate.bundleID && $0.launchDate == candidate.launchDate }) else { continue }
            guard owned.count < 32 else {
                error = "Focus hiding has 32 pending app restores. Restore Apps before hiding more applications."
                break
            }
            // Save ownership first so an unexpected exit does not lose Undo.
            owned.append(candidate); persistRecovery()
            if !hideApp(candidate.processID) {
                owned.removeAll { $0 == candidate }; persistRecovery()
                error = "macOS could not hide \(candidate.bundleID)."
            }

        }
        hiddenCount = owned.count
    }
    func restore() {
        let candidates = FocusAppPolicy.restoreCandidates(owned: owned, running: snapshots())
        var failed: [FocusAppSnapshot] = []
        for candidate in candidates {
            if !unhideApp(candidate.processID) { failed.append(candidate); error = "macOS could not restore \(candidate.bundleID). Try Restore Apps again." }
        }
        // Recovery retains the identity acquired before hiding, including its original state.
        // A live snapshot is only evidence that this same process still needs restoring.
        owned = owned.filter { saved in
            failed.contains { $0.processID == saved.processID && $0.bundleID == saved.bundleID && $0.launchDate == saved.launchDate }
        }
        hiddenCount = owned.count
        persistRecovery()
        if !blocked && failed.isEmpty { error = nil }
    }
    private func persistRecovery() {
        guard !blocked else { return }
        if owned.isEmpty { defaults.removeObject(forKey: Self.recoveryKey) }
        else if let prior = defaults.data(forKey: Self.recoveryKey),
                (try? JSONDecoder().decode([FocusAppSnapshot].self, from: prior)) == owned { return }
        else if let bytes = try? JSONEncoder().encode(owned) { defaults.set(bytes, forKey: Self.recoveryKey) }
    }
    func shutdown() { subscription?.cancel(); subscription = nil; restore(); active = false }
    func resetKeepingBackup() {
        if let value = defaults.object(forKey: Self.defaultsKey) { defaults.set(value, forKey: Self.defaultsKey + ".backup." + UUID().uuidString) }
        if let value = defaults.object(forKey: Self.recoveryKey) { defaults.set(value, forKey: Self.recoveryKey + ".backup." + UUID().uuidString) }
        defaults.removeObject(forKey: Self.defaultsKey); blocked = false; restore(); active = false
        configuration = .init()
        if owned.isEmpty { defaults.removeObject(forKey: Self.recoveryKey); error = nil }
    }
}

@MainActor
struct FocusAppHidingSettingsView: View {
    @ObservedObject var store: FocusAppHidingStore
    init(store: FocusAppHidingStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Focus app hiding", systemImage: "eye.slash").font(.headline)
            Text("Choose apps, preview the list, then enable. During an active Timers focus session, only those running apps are hidden. Pause, completion, cancellation or Disable restores apps this session hid. No apps are launched or quit.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose Applications…") { store.chooseApp() }
            ForEach(store.configuration.bundleIDs, id: \.self) { id in
                HStack { Text(id); Spacer(); Button("Remove") { store.remove(id) } }
            }
            Button("Preview Running Apps") { store.refreshPreview() }
            if store.preview.isEmpty { Text("No chosen visible running applications would be hidden.").font(.caption) }
            ForEach(store.preview, id: \.processID) { app in Text("Hide: \(app.bundleID)").font(.caption) }
            Toggle("Hide chosen apps during focus", isOn: Binding(get: { store.configuration.enabled }, set: { store.setEnabled($0) }))
                .disabled(store.configuration.bundleIDs.isEmpty)
            Button("Restore Apps Now") { store.restore() }.disabled(store.hiddenCount == 0)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("Reset Choices (Keep Backup)") { store.resetKeepingBackup() }
        }.onAppear { store.refreshPreview() }
    }
}
