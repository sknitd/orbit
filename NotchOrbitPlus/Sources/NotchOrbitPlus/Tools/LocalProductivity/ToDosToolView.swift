import SwiftUI
import NotchCore

@MainActor
final class ToDosToolStore: ObservableObject {
    static let shared = ToDosToolStore()
    @Published var items: [ToDoItem] = []
    @Published var error: String?
    private var dirty = false
    init() {
        do { items = try LocalToolStorage.load([ToDoItem].self, file: "todos.json", fallback: []) }
        catch { self.error = "Could not load tasks: \(error.localizedDescription)" }
    }
    private func save() {
        dirty = true
        do { try LocalToolStorage.save(items, file: "todos.json"); error = nil; dirty = false; PlusSyncService.shared.tasksDidSave(items) }
        catch { self.error = "Could not save tasks: \(error.localizedDescription)"; PlusSyncService.shared.reportUnsavedLocalChanges() }
    }
    func flushBeforeSync() { if dirty { save() } }
    func reloadAfterSync() {
        guard !dirty else { return }
        do { items = try LocalToolStorage.load([ToDoItem].self, file: "todos.json", fallback: []); error = nil }
        catch { self.error = "Could not reload synced tasks; current list retained: \(error.localizedDescription)" }
    }
    @discardableResult
    func add(_ value: String) -> Bool {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard title.count <= 500, items.count < 1_000 else {
            error = "Use at most 500 characters per task and 1,000 tasks."
            return false
        }
        items.insert(ToDoItem(title: title), at: 0)
        save()
        return true
    }
    func toggleCompleted(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].completed.toggle(); save()
    }
    func toggleStar(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].starred.toggle(); save()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func clearCompleted() { items.removeAll(where: \.completed); save() }
}

@MainActor
struct ToDosToolView: View {
    @StateObject private var store = ToDosToolStore.shared
    @ObservedObject private var sync = PlusSyncService.shared
    @State private var draft = ""
    @State private var filter = "open"
    private var visible: [ToDoItem] {
        store.items.filter { filter == "all" || (filter == "done" ? $0.completed : !$0.completed) }
            .sorted { $0.starred != $1.starred ? $0.starred : $0.createdAt > $1.createdAt }
    }
    private func add() { if store.add(draft) { draft = "" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a task", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Picker("Tasks", selection: $filter) {
                    Text("Open").tag("open"); Text("Completed").tag("done"); Text("All").tag("all")
                }.pickerStyle(.segmented)
                Button("Clear Completed", action: store.clearCompleted).disabled(!store.items.contains(where: \.completed))
            }
            LocalToolError(message: store.error)
            List(visible) { item in
                HStack {
                    Toggle(item.title, isOn: Binding(get: { item.completed }, set: { _ in store.toggleCompleted(item.id) }))
                        .strikethrough(item.completed).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.toggleStar(item.id) } label: {
                        Image(systemName: item.starred ? "star.fill" : "star")
                    }.buttonStyle(.borderless).accessibilityLabel(item.starred ? "Unstar task" : "Star task")
                    Button { store.remove(item.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Delete task")
                }
            }.frame(height: 200)
            Text("\(store.items.filter { !$0.completed }.count) open · \(sync.enabled ? "Shared folder sync enabled" : "Saved on this Mac")")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
            .onReceive(NotificationCenter.default.publisher(for: .plusSyncWillReadLocal)) { _ in store.flushBeforeSync() }
            .onReceive(NotificationCenter.default.publisher(for: .plusSyncLocalDidChange)) { _ in store.reloadAfterSync() }
    }
}
