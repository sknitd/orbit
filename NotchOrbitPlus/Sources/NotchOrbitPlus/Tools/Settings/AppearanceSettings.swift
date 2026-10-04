import AppKit
import SwiftUI
import NotchCore

@MainActor
final class PlusAppearanceStore: ObservableObject {
    static let shared = PlusAppearanceStore()
    static let defaultsKey = "plus.appearance.v1"
    @Published private(set) var settings = CoreAppearancePreferences()
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let onChange: @MainActor () -> Void
    init(defaults: UserDefaults = .standard, onChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.settingsDidChange() }) {
        self.defaults = defaults; self.onChange = onChange
        do { if let data = try PlusPortableDefaults.data(Self.defaultsKey, in: defaults) { settings = try CoreAppearancePreferences.decode(data) } }
        catch { self.error = "Stored appearance settings could not be read. Their original bytes are retained; reset with a backup to make changes." }
    }
    var preferredColorScheme: ColorScheme? {
        switch settings.theme { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var panelAppearance: NSAppearance? {
        switch settings.theme { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
    var accentColor: Color {
        switch settings.accent {
        case .system: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }
    func validateSyncApply(_ value: CoreAppearancePreferences) throws {
        _ = try value.encoded()
        if let existing = try PlusPortableDefaults.data(Self.defaultsKey, in: defaults) { _ = try CoreAppearancePreferences.decode(existing) }
    }
    func exportSyncSettings() throws -> CoreAppearancePreferences { try validateSyncApply(settings); return settings }
    func applySynced(_ value: CoreAppearancePreferences) throws {
        try validateSyncApply(value)
        defaults.set(try value.encoded(), forKey: Self.defaultsKey); settings = value; error = nil
    }
    func prepareSyncRollback() -> @MainActor () -> Void {
        let old = settings, oldError = error, raw = defaults.object(forKey: Self.defaultsKey)
        return {
            self.settings = old; self.error = oldError
            if let raw { self.defaults.set(raw, forKey: Self.defaultsKey) } else { self.defaults.removeObject(forKey: Self.defaultsKey) }
        }
    }
    func update(theme: PlusTheme? = nil, accent: PlusAccent? = nil, dropSound: Bool? = nil) {
        var value = settings
        if let theme { value.theme = theme }; if let accent { value.accent = accent }; if let dropSound { value.dropSound = dropSound }
        do { try applySynced(value); onChange() }
        catch { self.error = "Appearance change was not saved; the original is retained: \(error.localizedDescription)" }
    }
    func resetKeepingBackup() {
        if let existing = defaults.object(forKey: Self.defaultsKey) { defaults.set(existing, forKey: "\(Self.defaultsKey).backup.\(UUID().uuidString)") }
        defaults.removeObject(forKey: Self.defaultsKey)
        do { try applySynced(CoreAppearancePreferences()); onChange() }
        catch { self.error = error.localizedDescription }
    }
    /// Root calls this only after a successful explicit drop. Merely rendering settings never plays audio.
    func playDropSoundIfEnabled() {
        guard settings.dropSound else { return }
        NSSound(named: NSSound.Name("Pop"))?.play()
    }
}

@MainActor
struct AppearanceSettingsView: View {
    @ObservedObject private var store: PlusAppearanceStore
    init(store: PlusAppearanceStore = .shared) { self.store = store }
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { store.settings.theme }, set: { store.update(theme: $0) })) {
                    ForEach(PlusTheme.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Accent", selection: Binding(get: { store.settings.accent }, set: { store.update(accent: $0) })) {
                    ForEach(PlusAccent.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Play a sound after a successful drop", isOn: Binding(get: { store.settings.dropSound }, set: { store.update(dropSound: $0) }))
                Text("Drop sound is off by default. These appearance choices can sync; display geometry and permissions stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Button("Reset Appearance (Keep Backup)") { store.resetKeepingBackup() }
            }
        }.formStyle(.grouped)
    }
}
