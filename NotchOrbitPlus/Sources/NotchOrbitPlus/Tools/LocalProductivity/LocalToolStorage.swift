import AppKit
import SwiftUI
import NotchCore

enum LocalToolStorage {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("NotchOrbitPlus/LocalTools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }
    static func load<Value: Decodable>(_ type: Value.Type, file: String, fallback: Value) throws -> Value {
        let url = try directory().appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 40 * 1_024 * 1_024 {
            throw CocoaError(.fileReadTooLarge)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func save<Value: Codable>(_ value: Value, file: String) throws {
        let url = try directory().appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let valid = size <= 40 * 1_024 * 1_024 &&
                (try? JSONDecoder().decode(Value.self, from: Data(contentsOf: url))) != nil
            if !valid {
                // A user action may create fresh state after a load error, but
                // it must not destroy the unreadable original in the process.
                let backup = url.deletingLastPathComponent().appendingPathComponent("\(file).\(UUID().uuidString).backup")
                try FileManager.default.copyItem(at: url, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Prepare and validate all legacy files before applying a sync snapshot; keep rollback copies until the set is durable.
    @MainActor
    static func applySyncState(_ snapshot: SyncSnapshot, in storageDirectory: URL? = nil) throws {
        let root = try storageDirectory ?? directory()
        var replacements: [(name: String, bytes: Data, previous: Data?)] = []
        if let text = snapshot.note.preferred(on: snapshot.deviceID) {
            let url = root.appendingPathComponent("quick-note.txt")
            let old = try PlusSyncFolderIO.hasNode(url) ? try PlusSyncFolderIO.boundedData(url, limit: 200_000) : nil
            if let old, String(data: old, encoding: .utf8) == nil { throw SyncFailure.invalid("The original note is not valid UTF-8; nothing was replaced.") }
            replacements.append(("quick-note.txt", Data(text.utf8), old))
        }
        let taskURL = root.appendingPathComponent("todos.json")
        let oldTasks = try PlusSyncFolderIO.hasNode(taskURL) ? try PlusSyncFolderIO.boundedData(taskURL, limit: 4 * 1024 * 1024) : nil
        if let oldTasks {
            let values = try JSONDecoder().decode([ToDoItem].self, from: oldTasks)
            var validating = SyncSnapshot(deviceID: snapshot.deviceID); try validating.captureTasks(values)
        }
        replacements.append(("todos.json", try JSONEncoder().encode(snapshot.visibleTasks()), oldTasks))
        let ledgerURL = root.appendingPathComponent("sync-state-v1.json")
        let oldLedger = try PlusSyncFolderIO.hasNode(ledgerURL) ? try PlusSyncFolderIO.boundedData(ledgerURL, limit: SyncSnapshot.maximumBytes) : nil
        if let oldLedger { _ = try SyncSnapshot.decode(oldLedger) }
        replacements.append(("sync-state-v1.json", try snapshot.encoded(), oldLedger))
        let recovery = root.appendingPathComponent("SyncLocalRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for replacement in replacements {
            if let previous = replacement.previous {
                let backup = recovery.appendingPathComponent(replacement.name)
                try previous.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        var committed: [Int] = []
        do {
            for index in replacements.indices {
                let target = root.appendingPathComponent(replacements[index].name)
                try replacements[index].bytes.write(to: target, options: .atomic)
                committed.append(index)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            try FileManager.default.removeItem(at: recovery)
        } catch {
            var restored = true
            for index in committed.reversed() {
                let target = root.appendingPathComponent(replacements[index].name)
                do {
                    if let previous = replacements[index].previous { try previous.write(to: target, options: .atomic) }
                    else { try FileManager.default.removeItem(at: target) }
                } catch { restored = false }
            }
            if restored { try? FileManager.default.removeItem(at: recovery); throw error }
            throw SyncFailure.invalid("Local sync application failed. Original recovery copies remain in \(recovery.lastPathComponent).")
        }
    }
}

struct LocalToolError: View {
    let message: String?
    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
