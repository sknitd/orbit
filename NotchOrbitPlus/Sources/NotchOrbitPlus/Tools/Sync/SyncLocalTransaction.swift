import Foundation
import NotchCore

/// Recovery copies are private to this Mac, and never enter the shared sync folder.
struct PlusSyncLocalApplyFailure: LocalizedError {
    let cause: any Error
    let recoveryDirectory: URL?
    var errorDescription: String? {
        if let recoveryDirectory {
            return "Local sync application and recovery could not finish. Some local stores may contain incoming data. Sync is paused; original files and preferences remain in \(recoveryDirectory.lastPathComponent)."
        }
        return "Incoming sync data was not kept; the previous local files and preferences were restored. \(cause.localizedDescription)"
    }
}

/// Extends the legacy note/task/ledger transaction to the whole synchronous MainActor apply.
/// Persist originals before the first mutation; restore memory without re-saving a failing store.
@MainActor
final class PlusSyncLocalTransaction {
    struct FileOriginal: Codable {
        let name: String
        let existed: Bool
        let permissions: Int?
    }
    private struct Manifest: Codable {
        let version: Int
        let files: [FileOriginal]
        let defaultsKeys: [String]
    }
    let recoveryDirectory: URL
    private let root: URL
    private let defaults: UserDefaults
    private let originals: [FileOriginal]
    private let defaultsKeys: [String]
    private let defaultsValues: [String: Any]
    private var rollbacks: [@MainActor () throws -> Void] = []

    init(in root: URL, files: [(name: String, limit: Int)],
         defaults: UserDefaults = .standard, defaultsKeys: [String] = []) throws {
        self.root = root; self.defaults = defaults; self.defaultsKeys = defaultsKeys
        guard try Self.pendingRecovery(in: root) == nil else {
            throw SyncFailure.invalid("A previous local sync transaction needs recovery; no further local sync writes were started.")
        }
        guard Set(files.map(\.name)).count == files.count,
              files.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("/") && !$0.name.contains("\\") && $0.name != "." && $0.name != ".." }),
              Set(defaultsKeys).count == defaultsKeys.count else {
            throw SyncFailure.invalid("Invalid local recovery file or preference names.")
        }
        var captured: [(FileOriginal, Data?)] = []
        for file in files {
            let url = root.appendingPathComponent(file.name)
            let existed = try PlusSyncFolderIO.hasNode(url)
            let data = existed ? try PlusSyncFolderIO.boundedData(url, limit: file.limit) : nil
            let permissions = existed ? (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue : nil
            captured.append((FileOriginal(name: file.name, existed: existed, permissions: permissions), data))
        }
        originals = captured.map(\.0)
        defaultsValues = Dictionary(uniqueKeysWithValues: defaultsKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        let preferenceData = try PropertyListSerialization.data(fromPropertyList: defaultsValues, format: .binary, options: 0)
        guard preferenceData.count <= SyncSnapshot.maximumBytes else { throw SyncFailure.invalid("Local preference recovery exceeds its size limit.") }
        recoveryDirectory = root.appendingPathComponent("SyncLocalRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (file, bytes) in captured {
                if let bytes { try writePrivate(bytes, to: recoveryDirectory.appendingPathComponent(file.name)) }
            }
            try writePrivate(preferenceData, to: recoveryDirectory.appendingPathComponent("defaults.plist"))
            let manifest = Manifest(version: 1, files: originals, defaultsKeys: defaultsKeys)
            try writePrivate(JSONEncoder().encode(manifest), to: recoveryDirectory.appendingPathComponent("transaction-recovery.json"))
        } catch {
            try? FileManager.default.removeItem(at: recoveryDirectory)
            throw error
        }
    }

    func addRollback(_ restore: @escaping @MainActor () throws -> Void) { rollbacks.append(restore) }

    func apply(_ snapshot: SyncSnapshot, additionalStores: () throws -> Void) throws {
        do {
            try LocalToolStorage.applySyncState(snapshot, in: root)
            try additionalStores()
            // A crash after this marker means all stores were applied; stale backups do not block launch.
            // The parent is private (0700). Do not perform a fallible chmod after
            // publishing this marker: no throwing operation may follow commit.
            try Data("All local stores committed.\n".utf8).write(to: recoveryDirectory.appendingPathComponent("COMMITTED"), options: .atomic)
            try? FileManager.default.removeItem(at: recoveryDirectory)
        } catch {
            let cause = error
            var restored = true
            for restore in rollbacks.reversed() {
                do { try restore() } catch { restored = false }
            }
            for key in defaultsKeys {
                if let original = defaultsValues[key] { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for file in originals.reversed() {
                let target = root.appendingPathComponent(file.name)
                do {
                    // Do not overwrite a newly encountered directory or link during recovery.
                    if try PlusSyncFolderIO.hasNode(target) { _ = try PlusSyncFolderIO.boundedData(target, limit: SyncSnapshot.maximumBytes) }
                    if file.existed {
                        let backup = recoveryDirectory.appendingPathComponent(file.name)
                        let data = try PlusSyncFolderIO.boundedData(backup, limit: SyncSnapshot.maximumBytes)
                        try data.write(to: target, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: file.permissions ?? 0o600], ofItemAtPath: target.path)
                    } else if try PlusSyncFolderIO.hasNode(target) {
                        try FileManager.default.removeItem(at: target)
                    }
                } catch { restored = false }
            }
            if restored { try? FileManager.default.removeItem(at: recoveryDirectory) }
            throw PlusSyncLocalApplyFailure(cause: cause, recoveryDirectory: restored ? nil : recoveryDirectory)
        }
    }

    static func pendingRecovery(in root: URL) throws -> URL? {
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.lastPathComponent.hasPrefix("SyncLocalRecovery-") {
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            if try PlusSyncFolderIO.hasNode(url.appendingPathComponent("transaction-recovery.json")),
               !(try PlusSyncFolderIO.hasNode(url.appendingPathComponent("COMMITTED"))) { return url }
        }
        return nil
    }

    private func writePrivate(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
