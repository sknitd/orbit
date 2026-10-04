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
                    Button("Sync Now") { sync.syncNow() }.disabled(!sync.enabled || sync.isSyncing || sync.recoveryDirectory != nil)
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    if let date = sync.lastSyncAt { Text("Last pass \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                }
                Text(sync.status).font(.caption).foregroundStyle(.secondary)
                if let error = sync.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if sync.recoveryDirectory != nil {
                    Button("Show Private Recovery Copies") { sync.showRecoveryFolder() }
                    Text("Some local stores may contain incoming data. Sync stays paused across relaunches. Recover the original files and defaults.plist from this private folder before removing it and reopening the app.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("What is shared") {
                Text("Quick Note, To-Dos, eligible ordinary-text snippets, habits, named shelves and rule descriptions, logical launcher pins, workflow presets, saved color palettes, tool order, hidden tools, hover/click behavior, appearance, live-status priorities and saved World Clock zones.")
                Text("API credentials, clipboard history, File Shelf contents, meeting data, display size/selection, keyboard permissions, bookmarks and account configuration stay local.").font(.caption).foregroundStyle(.secondary)
                Text("Snapshots are readable JSON in the folder you choose. Your folder provider controls encryption, access and delivery. A successful write confirms only this Mac’s local folder write.").font(.caption).foregroundStyle(.secondary)
                Text("Independent task edits merge by field. Deletions leave tombstones so an offline Mac cannot recreate a removed task. Conflicting notes or preferences stay as variants until you choose; discarded variants are backed up locally before resolution.").font(.caption).foregroundStyle(.secondary)
                Text("Applications sync by bundle identifier and Shortcuts by identifier. Synced folder pins need an explicit local folder choice on each Mac. Paths, bookmarks and color-picking history stay local. Concurrent edits to the same library retain complete variants; different library categories merge independently.").font(.caption).foregroundStyle(.secondary)
                Text("Use the current version on every Mac. Version 3 reads older snapshots safely; older apps reject new snapshots without replacing their originals. Local-only snippets, verification codes, watched-folder bookmarks, shelf contents, Inbox configuration and rule enablement are excluded. Changed incoming rules need a local preview and enable action.").font(.caption).foregroundStyle(.secondary)
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
                            if let appearance = revision.value.appearance { Text("\(appearance.theme.rawValue.capitalized) · \(appearance.accent.rawValue.capitalized) · Drop sound \(appearance.dropSound ? "on" : "off")").font(.caption) }
                            if let priority = revision.value.livePriority { Text(priority.order.map(\.title).joined(separator: " → ")).font(.caption).lineLimit(3) }
                            if let zones = revision.value.worldZoneIDs { Text("World Clock: \(zones.joined(separator: ", "))").font(.caption).lineLimit(3) }
                            Button("Use This Settings Variant") { sync.resolveSettings(revision.id) }.disabled(sync.isSyncing)
                        }
                    }
                }
            }
            if sync.state.launcherPins.hasConflict {
                Section("Launcher conflict — choose intentionally") {
                    ForEach(sync.state.launcherPins.revisions) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.value.count) targets").font(.caption)
                            Text(revision.value.prefix(8).map(\.label).joined(separator: ", ")).font(.caption).lineLimit(3)
                            Button("Use These Launcher Pins") { sync.resolvePortable(.launcher, revisionID: revision.id) }.disabled(sync.isSyncing)
                        }
                    }
                }
            }
            if sync.state.workflows.hasConflict {
                Section("Workflow conflict — choose intentionally") {
                    ForEach(sync.state.workflows.revisions) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.value.count) presets").font(.caption)
                            Text(revision.value.prefix(8).map(\.name).joined(separator: ", ")).font(.caption).lineLimit(3)
                            Button("Use These Workflow Presets") { sync.resolvePortable(.workflows, revisionID: revision.id) }.disabled(sync.isSyncing)
                        }
                    }
                }
            }
            if sync.state.palettes.hasConflict {
                Section("Palette conflict — choose intentionally") {
                    ForEach(sync.state.palettes.revisions) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.value.palettes.count) palettes").font(.caption)
                            Text(revision.value.palettes.prefix(8).map(\.name).joined(separator: ", ")).font(.caption).lineLimit(3)
                            Button("Use These Saved Palettes") { sync.resolvePortable(.palettes, revisionID: revision.id) }.disabled(sync.isSyncing)
                        }
                    }
                }
            }
            if sync.state.snippets.hasConflict {
                Section("Snippets conflict — choose intentionally") {
                    ForEach(sync.state.snippets.revisions) { revision in
                        Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.value.snippets.count) eligible snippets").font(.caption)
                        Button("Use These Shared Snippets") { sync.resolvePortable(.snippets, revisionID: revision.id) }.disabled(sync.isSyncing || sync.recoveryDirectory != nil)
                    }
                }
            }
            if sync.state.habits.hasConflict {
                Section("Habits conflict — choose intentionally") {
                    ForEach(sync.state.habits.revisions) { revision in
                        Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.value.habits.count) habits · \(revision.value.habits.reduce(0) { $0 + $1.checkedDays.count }) checkoffs").font(.caption)
                        Button("Use This Habit History") { sync.resolvePortable(.habits, revisionID: revision.id) }.disabled(sync.isSyncing || sync.recoveryDirectory != nil)
                    }
                }
            }
            if sync.state.shelves.hasConflict {
                Section("Shelf configuration conflict — choose intentionally") {
                    ForEach(sync.state.shelves.revisions) { revision in
                        Text("Device \(revision.deviceID.uuidString.prefix(8)) · \(revision.value.shelves.count) named shelves · \(revision.value.rules.count) rule descriptions").font(.caption)
                        Button("Use These Shelf Descriptions") { sync.resolvePortable(.shelves, revisionID: revision.id) }.disabled(sync.isSyncing || sync.recoveryDirectory != nil)
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
