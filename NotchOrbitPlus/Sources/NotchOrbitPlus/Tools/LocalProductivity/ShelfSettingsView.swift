import SwiftUI
import NotchCore

@MainActor struct ShelfSettingsView: View {
    @ObservedObject private var shelf: FileShelfToolStore
    @ObservedObject private var store: ShelfCollectionsStore
    @State private var newShelf = ""
    @State private var editing: CoreShelfRule?
    @Environment(\.dismiss) private var dismiss
    init(store: FileShelfToolStore = .shared) { shelf = store; self.store = store.collections }
    var body: some View {
        Form {
            Section("Named shelves") {
                HStack { TextField("New shelf name", text: $newShelf); Button("Add") { if store.addShelf(newShelf) { newShelf = "" } }.disabled(newShelf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(store.shelves) { shelf in Text(shelf.name) }
                Text("Switch shelves in File Shelf. Drag an entry onto a shelf name or use Move; this changes only the shelf index.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Rules — off until previewed and enabled") {
                Button("Add Rule") { editing = CoreShelfRule(name: "", kind: .captures) }
                ForEach(store.rules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(rule.name).font(.headline); Spacer(); Text(store.isEnabled(rule.id) ? "Enabled on this Mac" : "Off").font(.caption) }
                        Text("\(title(rule.kind)) → \(store.shelves.first(where: { $0.id == rule.shelfID })?.name ?? "Inbox")").font(.caption)
                        HStack {
                            Button("Edit") { editing = rule }; Button("Preview") { shelf.previewRule(rule) }
                            if rule.kind == .watchFolder { Button("Choose Folder…") { store.chooseFolder(for: rule) } }
                            if store.isEnabled(rule.id) { Button("Disable") { store.disableRule(rule.id) } }
                            Button { store.moveRule(rule.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            Button { store.moveRule(rule.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            Button("Remove") { store.removeRule(rule.id) }
                        }.font(.caption)
                    }
                }
                Text("Capture rules route future owned capture copies and tags. Folder rules copy matching regular files (≤100 MB) from an explicitly chosen folder every 15 seconds. Background expiry moves managed copies to retained Undo trash, including while this tool is hidden; originals and references are excluded.").font(.caption).foregroundStyle(.secondary)
                Text("Expiry is off until you preview its exact definition and explicitly enable it. Undo disables matching local expiry rules; re-enable needs a fresh preview. Legacy Keep retention stays manual without an enabled expiry rule.").font(.caption).foregroundStyle(.secondary)
                if shelf.expiryRequiresRetry { Button("Retry Paused Automatic Expiry") { shelf.retryAutomaticExpiry() } }
                Text("Rule descriptions and named shelves may sync. Folder bookmarks, selected shelf and rule enablement stay local; changed incoming rules need a new local preview.").font(.caption).foregroundStyle(.secondary)
                if store.watching { Text("Watching readable chosen folders. Provider availability and access can still fail.").font(.caption) }
                LocalToolError(message: store.error)
            }
            Section("iPhone Orbit Inbox") { OrbitInboxSettingsView() }
            Button("Done") { dismiss() }
        }.formStyle(.grouped).sheet(item: $editing) { rule in
            ShelfRuleEditor(rule: rule, shelves: store.shelves, error: store.error) { value in if store.saveRule(value) { editing = nil } } cancel: { editing = nil }
                .onAppear { store.setEditorOpen(true) }.onDisappear { store.setEditorOpen(false) }
        }.sheet(item: $store.preview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview: \(preview.rule.name)").font(.headline)
                if preview.lines.isEmpty { Text("No matching entries at this time. No deletion or import has occurred.") }
                ScrollView { VStack(alignment: .leading) { ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 220)
                Text(preview.rule.kind == .watchFolder ? "Enable to copy the previewed matching files and future arrivals. Originals stay intact." : preview.rule.kind == .expireOwnedCopies ? "Enable to move these and future expired owned copies into retained Undo trash automatically, even while hidden. Originals and references remain intact." : "Enable to route future owned capture copies and tags on this Mac.").font(.caption).foregroundStyle(.secondary)
                LocalToolError(message: store.error)
                HStack {
                    Button("Close") { store.preview = nil }
                    Button("Enable on This Mac") { store.enablePreviewedRule(preview.rule.id) }
                    if !preview.cleanupIDs.isEmpty { Button("Confirm Retained Cleanup") { shelf.confirmCleanup(preview.cleanupIDs); if shelf.error == nil { store.preview = nil } } }
                }
            }.padding().frame(width: 470)
        }
    }
    private func title(_ kind: CoreShelfRuleKind) -> String { switch kind { case .captures: "Capture copies"; case .watchFolder: "Watch chosen folder"; case .expireOwnedCopies: "Move owned copies older than N days to retained trash" } }
}

@MainActor private struct ShelfRuleEditor: View {
    @State var rule: CoreShelfRule
    let shelves: [CoreShelfCollection]
    let error: String?
    let save: (CoreShelfRule) -> Void
    let cancel: () -> Void
    @State private var tags = ""
    @State private var extensions = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shelf Rule").font(.headline); TextField("Name", text: $rule.name).textFieldStyle(.roundedBorder)
            Picker("Action", selection: $rule.kind) { Text("Capture copies + tags").tag(CoreShelfRuleKind.captures); Text("Watch chosen folder + copy").tag(CoreShelfRuleKind.watchFolder); Text("Owned-copy expiry to retained trash").tag(CoreShelfRuleKind.expireOwnedCopies) }
            Picker("Destination shelf", selection: $rule.shelfID) { ForEach(shelves) { Text($0.name).tag($0.id) } }
            if rule.kind == .expireOwnedCopies { Stepper("Older than \(rule.days) days", value: $rule.days, in: 1...365) }
            else { TextField("Tags, comma separated", text: $tags).textFieldStyle(.roundedBorder); TextField("Extensions: png, pdf (empty = all)", text: $extensions).textFieldStyle(.roundedBorder) }
            Text("Saving switches this rule off. Choose a watched folder separately, then Preview and explicitly Enable. No original file is deleted.").font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: error)
            HStack { Button("Cancel", action: cancel); Spacer(); Button("Save Off") {
                rule.tags = ShelfFileMetadata.normalizedTags(tags.split(separator: ",").map(String.init))
                rule.fileExtensions = extensions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                save(rule)
            } }
        }.padding().frame(width: 440).onAppear { tags = rule.tags.joined(separator: ", "); extensions = rule.fileExtensions.joined(separator: ", ") }
    }
}

@MainActor struct ShelfCleanupPreviewView: View {
    @ObservedObject var store: FileShelfToolStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Owned-copy cleanup preview").font(.headline)
            let ids = store.cleanupPreview?.itemIDs ?? []
            Text("\(ids.count) owned copies eligible; \(store.cleanupPreview?.excludedReferences ?? 0) expired references excluded. No original file will be deleted.")
            ScrollView { VStack(alignment: .leading) { ForEach(store.items.filter { ids.contains($0.id) }) { Text($0.originalURL.lastPathComponent).font(.caption) } } }.frame(maxHeight: 200)
            Text("Confirm moves owned copies into private retained trash and removes their index entries. Undo is available after relaunch; retained backups are not purged automatically.").font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: store.error)
            HStack { Button("Cancel", action: close); Spacer(); Button("Confirm Retained Cleanup") { store.confirmCleanup(ids); if store.error == nil { close() } }.disabled(ids.isEmpty) }
        }.padding().frame(width: 460)
    }
}
