import SwiftUI
import NotchCore

@MainActor
struct SyncSettingsView: View {
    @ObservedObject private var sync = PlusSyncService.shared
    var body: some View {
        Form {
            Section("Optional sync across Macs") {
                Text("Choose the same shared folder on each Mac. iCloud Drive, Dropbox or a network folder can deliver the files through their existing setup; this app does not create a cloud account.").font(.callout)
                HStack { Button("Choose Shared Folder…") { sync.chooseFolder() }; Text(sync.folderName).foregroundStyle(.secondary) }
                Toggle("Enable notes, tasks and shared preferences sync", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                HStack {
                    Button("Sync Now") { sync.syncNow() }.disabled(!sync.enabled || sync.isSyncing)
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    if let date = sync.lastSyncAt { Text("Last pass \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
                Text(sync.status).font(.caption).foregroundStyle(.secondary)
                if let error = sync.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Section("What is shared") {
                Text("Quick Note, To-Dos, tool order, hidden tools, hover/click open mode and hover delay.")
                Text("API credentials, clipboard history, File Shelf contents, meeting data, display size/selection, keyboard permissions, bookmarks and account configuration stay local.").font(.caption).foregroundStyle(.secondary)
                Text("Snapshots are readable JSON in the folder you choose. Your folder provider controls encryption, access and delivery. A successful write confirms only this Mac’s local folder write.").font(.caption).foregroundStyle(.secondary)
                Text("Independent task edits merge by field. Deletions leave tombstones so an offline Mac cannot recreate a removed task. Conflicting notes or preferences stay as variants until you choose; discarded variants are backed up locally before resolution.").font(.caption).foregroundStyle(.secondary)
            }
            if sync.state.note.hasConflict {
                Section("Note conflict — choose intentionally") {
                    ForEach(sync.state.note.revisions) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.writtenAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            Text(String(revision.value.prefix(240))).lineLimit(5).textSelection(.enabled)
                            Button("Use This Note Variant") { sync.resolveNote(revision.id) }.disabled(sync.isSyncing)
                        }
                    }
                }
            }
            if sync.state.settings.hasConflict {
                Section("Settings conflict — choose intentionally") {
                    ForEach(sync.state.settings.revisions) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.writtenAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            Text("\(revision.value.openMode == "clickOnly" ? "Click only" : "Hover or click") · \(revision.value.hoverDelay, specifier: "%.2f") s · \(revision.value.hiddenToolIDs.count) hidden tools").font(.caption)
                            Button("Use This Settings Variant") { sync.resolveSettings(revision.id) }.disabled(sync.isSyncing)
                        }
                    }
                }
            }
            Section("Metadata and limits") {
                Text("\(sync.state.tasks.filter(\.isDeleted).count) deletion tombstones retained · \(sync.state.conflictCount) conflict group(s). Limits: 1,000 active tasks, 2,000 task/tombstone records, 200 KB per note, 8 MB per snapshot and sixteen device/conflict files.").font(.caption).foregroundStyle(.secondary)
                Button("Reset Local Sync Metadata (Keep Backup)") { sync.resetMetadataPreservingBackup() }.disabled(sync.isSyncing)
                Text("Reset disables sync and preserves a metadata backup. It does not delete local notes/tasks or shared device files.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
