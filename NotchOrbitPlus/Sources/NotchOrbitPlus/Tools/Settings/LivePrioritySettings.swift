import SwiftUI
import NotchCore

@MainActor
final class PlusLivePriorityStore: ObservableObject {
    static let shared = PlusLivePriorityStore()
    static let defaultsKey = "plus.livePriorities.v1"
    @Published private(set) var configuration = LiveNotchPriorityConfiguration()
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let onChange: @MainActor () -> Void
    init(defaults: UserDefaults = .standard, onChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.settingsDidChange() }) {
        self.defaults = defaults; self.onChange = onChange
        do { if let data = try PlusPortableDefaults.data(Self.defaultsKey, in: defaults) { configuration = try LiveNotchPriorityConfiguration.decode(data) } }
        catch { self.error = "Stored priorities could not be read. Their original bytes are retained; reset with a backup to change them." }
    }
    var priorityOrder: [LiveNotchKind] { configuration.order }
    func validateSyncApply(_ value: LiveNotchPriorityConfiguration) throws {
        try value.validate()
        if let existing = try PlusPortableDefaults.data(Self.defaultsKey, in: defaults) { _ = try LiveNotchPriorityConfiguration.decode(existing) }
    }
    func exportSyncSettings() throws -> LiveNotchPriorityConfiguration { try validateSyncApply(configuration); return configuration }
    func applySynced(_ value: LiveNotchPriorityConfiguration) throws {
        try validateSyncApply(value)
        defaults.set(try value.encoded(), forKey: Self.defaultsKey); configuration = value; error = nil
    }
    func move(_ kind: LiveNotchKind, by offset: Int) {
        guard let index = priorityOrder.firstIndex(of: kind), priorityOrder.indices.contains(index + offset) else { return }
        var next = priorityOrder; next.swapAt(index, index + offset)
        do { try applySynced(LiveNotchPriorityConfiguration(order: next)); onChange() }
        catch { self.error = "Priority change was not saved; the original is retained: \(error.localizedDescription)" }
    }
    func resetKeepingBackup() {
        if let existing = defaults.object(forKey: Self.defaultsKey) { defaults.set(existing, forKey: "\(Self.defaultsKey).backup.\(UUID().uuidString)") }
        defaults.removeObject(forKey: Self.defaultsKey)
        do { try applySynced(LiveNotchPriorityConfiguration()); onChange() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct LivePrioritySettingsView: View {
    @ObservedObject private var store: PlusLivePriorityStore
    init(store: PlusLivePriorityStore = .shared) { self.store = store }
    var body: some View {
        Form {
            Section("Compact notch priority") {
                Text("The first available status in this order gets the main row. Other active statuses remain available as indicators.").font(.caption).foregroundStyle(.secondary)
                ForEach(store.priorityOrder, id: \.self) { kind in
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer()
                        Button { store.move(kind, by: -1) } label: { Image(systemName: "arrow.up") }
                            .accessibilityLabel("Move \(kind.title) up").disabled(store.priorityOrder.first == kind)
                        Button { store.move(kind, by: 1) } label: { Image(systemName: "arrow.down") }
                            .accessibilityLabel("Move \(kind.title) down").disabled(store.priorityOrder.last == kind)
                    }
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Button("Reset Priorities (Keep Backup)") { store.resetKeepingBackup() }
            }
        }.formStyle(.grouped)
    }
}
