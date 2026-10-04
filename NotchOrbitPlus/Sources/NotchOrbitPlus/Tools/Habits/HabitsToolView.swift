import SwiftUI
import NotchCore

@MainActor final class HabitsStore: ObservableObject {
    static let shared = HabitsStore()
    static let fileName = "habits-v1.json"
    @Published private(set) var library = CoreHabitLibrary()
    @Published private(set) var error: String?
    @Published private(set) var today = CoreHabitCalendar.key(for: Date())
    private var url: URL?
    private let onChange: @MainActor () -> Void
    private var ticker: Task<Void, Never>?
    init(directory: URL? = nil, onChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.portableDidChange() }) {
        self.onChange = onChange
        do { let root = try directory ?? LocalToolStorage.directory(); url = root.appendingPathComponent(Self.fileName)
            library = try PlusPortableLibraryFile.load(at: url!, limit: CoreHabitLibrary.maximumBytes, decode: CoreHabitLibrary.decode) ?? .init()
        } catch { url = nil; self.error = "Habits could not be read; the original is retained: \(error.localizedDescription)" }
    }
    deinit { ticker?.cancel() }
    func start() {
        refreshDay(); guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in while !Task.isCancelled { do { try await Task.sleep(for: .seconds(60)) } catch { return }; self?.refreshDay() } }
    }
    func shutdown() { ticker?.cancel(); ticker = nil }
    private func refreshDay() { today = CoreHabitCalendar.key(for: Date()) }
    func exportSyncedLibrary() throws -> CoreHabitLibrary {
        guard let url else { throw SyncFailure.invalid("The unreadable habit original was retained.") }
        _ = try PlusPortableLibraryFile.load(at: url, limit: CoreHabitLibrary.maximumBytes, decode: CoreHabitLibrary.decode); return library
    }
    func validateSyncedLibrary(_ value: CoreHabitLibrary) throws { _ = try exportSyncedLibrary(); _ = try value.encoded() }
    func applySyncedLibrary(_ value: CoreHabitLibrary) throws { try validateSyncedLibrary(value); try persist(value) }
    func prepareSyncRollback() -> @MainActor () -> Void { let old = library, oldError = error; return { self.library = old; self.error = oldError } }
    func add(_ name: String) { edit { $0.habits.append(.init(name: name.trimmingCharacters(in: .whitespacesAndNewlines))) } }
    func remove(_ id: UUID) { edit { $0.habits.removeAll { $0.id == id } } }
    func toggleToday(_ id: UUID) { refreshDay(); do { var next = library; try next.toggle(id, day: today); try persist(next); onChange() } catch { self.error = error.localizedDescription } }
    private func edit(_ change: (inout CoreHabitLibrary) -> Void) { do { var next = library; change(&next); try persist(next); onChange() } catch { self.error = error.localizedDescription } }
    private func persist(_ value: CoreHabitLibrary) throws {
        guard let url else { throw SyncFailure.invalid("The unreadable habit original was retained.") }
        try PlusPortableLibraryFile.save(value.encoded(), at: url, limit: CoreHabitLibrary.maximumBytes, decode: CoreHabitLibrary.decode); library = value; error = nil
    }
}

@MainActor struct HabitsToolView: View {
    @ObservedObject private var store: HabitsStore
    @State private var name = ""
    @State private var deleting: CoreHabit?
    init(store: HabitsStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("New daily habit", text: $name).textFieldStyle(.roundedBorder); Button("Add") { store.add(name); if store.error == nil { name = "" } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            LocalToolError(message: store.error)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.library.habits) { habit in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Toggle(habit.name, isOn: Binding(get: { habit.checkedDays.contains(store.today) }, set: { _ in store.toggleToday(habit.id) })); Spacer(); Text("\(CoreHabitCalendar.streak(habit, today: store.today)) day streak").font(.caption); Button { deleting = habit } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(habit.name)") }
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(14), spacing: 3), count: 7), spacing: 3) {
                                ForEach(CoreHabitCalendar.heatmap(habit, through: store.today)) { day in RoundedRectangle(cornerRadius: 2).fill(day.checked ? Color.green : Color.secondary.opacity(0.15)).frame(width: 14, height: 14).help("\(day.id): \(day.checked ? "checked" : "not checked")").accessibilityLabel("\(day.id) \(day.checked ? "checked" : "not checked")") }
                            }
                        }
                    }
                    if store.library.habits.isEmpty { Text("Add a habit, then check off today. The heatmap shows the last seven weeks.").foregroundStyle(.secondary) }
                }
            }.frame(height: 265)
            Text("Today: \(store.today) in this Mac’s time zone. Yesterday’s streak remains until the end of today. Optional sync preserves concurrent library variants.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).onAppear { store.start() }.onDisappear { store.shutdown() }
            .confirmationDialog("Delete this habit and its checkoff history?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                if let deleting { Button("Delete \(deleting.name)", role: .destructive) { store.remove(deleting.id); self.deleting = nil } }
            }
    }
}
