import Foundation
import NotchCore

private final class SyncCoordinationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func set(_ value: Result<Value, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
    func get() throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw SyncFailure.invalid("The sync folder coordinator did not provide access.") }
        return try result.get()
    }
}

/// Each device writes only its own snapshot. Other device files and provider conflict copies are read-only inputs.
enum PlusSyncFolderIO {
    /// Unlike fileExists, lstat-backed attributes also see dangling symbolic links.
    static func hasNode(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(failure.code) { return false }
            throw error
        }
    }
    static func directory(in folder: URL) throws -> URL {
        let root = folder.appendingPathComponent("NotchOrbitPlusSync", isDirectory: true)
        if try hasNode(root) {
            let values = try FileManager.default.attributesOfItem(atPath: root.path)
            guard values[.type] as? FileAttributeType == .typeDirectory else { throw SyncFailure.invalid("The sync data directory is not a regular folder.") }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        return root
    }
    private static func regularFileSize(_ url: URL) throws -> Int {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else {
            throw SyncFailure.invalid("A sync snapshot must be a regular file, never a symbolic link.")
        }
        return (values[.size] as? NSNumber)?.intValue ?? Int.max
    }
    static func boundedData(_ url: URL, limit: Int) throws -> Data {
        guard try regularFileSize(url) <= limit else {
            throw SyncFailure.invalid("A sync file is unavailable, too large or not a regular file. Local originals were preserved.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw SyncFailure.invalid("A sync file grew beyond its size limit.") }
        return bytes
    }
    static func read(folder: URL) throws -> [SyncSnapshot] {
        try Task.checkCancellation()
        let root = try directory(in: folder)
        let box = SyncCoordinationBox<[SyncSnapshot]>()
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: root, options: [], error: &coordinationError) { directory in
            box.set(Result {
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
                let snapshots = urls.filter { $0.lastPathComponent.hasPrefix("device-") && $0.pathExtension == "json" }
                guard snapshots.count <= 16 else { throw SyncFailure.invalid("This folder has more than sixteen device/conflict snapshots. Sync is paused without replacing local data.") }
                return try snapshots.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                    try Task.checkCancellation()
                    let name = url.deletingPathExtension().lastPathComponent.dropFirst(7)
                    guard name.count >= 36, let expectedDevice = UUID(uuidString: String(name.prefix(36))) else {
                        throw SyncFailure.invalid("An unrecognized device snapshot name needs attention in the shared folder.")
                    }
                    let snapshot = try SyncSnapshot.decode(boundedData(url, limit: SyncSnapshot.maximumBytes))
                    guard snapshot.deviceID == expectedDevice else { throw SyncFailure.invalid("A device snapshot does not match its file identity.") }
                    return snapshot
                }
            })
        }
        if let coordinationError { throw coordinationError }
        return try box.get()
    }
    static func publish(_ snapshot: SyncSnapshot, folder: URL) throws -> SyncSnapshot {
        try Task.checkCancellation()
        let root = try directory(in: folder)
        let target = root.appendingPathComponent("device-\(snapshot.deviceID.uuidString.lowercased()).json")
        // Reject direct links before a coordinator could resolve their destination.
        if try hasNode(target) { _ = try regularFileSize(target) }
        let box = SyncCoordinationBox<SyncSnapshot>()
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forMerging, error: &coordinationError) { destination in
            box.set(Result {
                try Task.checkCancellation()
                var publishing = snapshot
                if try hasNode(destination) {
                    // Re-read under the write coordination lock, retaining any provider-side concurrent change.
                    let existing = try SyncSnapshot.decode(boundedData(destination, limit: SyncSnapshot.maximumBytes))
                    guard existing.deviceID == snapshot.deviceID else { throw SyncFailure.invalid("The local device’s shared file has a different identity; it was not replaced.") }
                    publishing = try SyncMerge.threeWay(base: snapshot, local: snapshot, remote: existing)
                }
                try publishing.encoded().write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return publishing
            })
        }
        if let coordinationError { throw coordinationError }
        return try box.get()
    }
}
