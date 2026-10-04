import Foundation
import CornerCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CornerPreferences: Codable, Equatable, Sendable {
    var settings: CornerSettings
    var automationEnabled: Bool
    var showHints: Bool
    init(settings: CornerSettings = .defaults, automationEnabled: Bool = false, showHints: Bool = false) {
        self.settings = settings; self.automationEnabled = automationEnabled; self.showHints = showHints
    }
    static let defaults = CornerPreferences()
    func validated() throws -> CornerPreferences {
        var result = self; result.settings = try settings.validated(); return result
    }
}

struct CornerPreferencesPersistence: Sendable {
    let directory: URL
    private let publish: @Sendable (URL, URL) throws -> Void
    /// The injected publisher is a fixture boundary: throw before committing,
    /// or atomically replace the destination. Production always uses rename.
    init(directory: URL, publish: (@Sendable (URL, URL) throws -> Void)? = nil) {
        self.directory = directory; self.publish = publish ?? Self.atomicPublish
    }
    var file: URL { directory.appendingPathComponent("settings.json") }
    static var live: CornerPreferencesPersistence {
        .init(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sknitd.CornerOrbit", isDirectory: true))
    }
    func load() throws -> CornerPreferences {
        guard let snapshot = try readExisting() else { return .defaults }
        return try JSONDecoder().decode(CornerPreferences.self, from: snapshot.bytes).validated()
    }
    func save(_ preferences: CornerPreferences) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences.validated())
        guard data.count <= 262_144 else { throw CornerActionError.invalid("The settings are too large to save.") }
        let existing = try readExisting()
        if let existing {
            do { _ = try JSONDecoder().decode(CornerPreferences.self, from: existing.bytes).validated() }
            catch { throw CornerActionError.invalid("Saved settings are unreadable and have been preserved. Preserve and reset them before saving changes.") }
        }
        guard directory.isFileURL else { throw CornerActionError.invalid("Settings require a local folder.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CornerActionError.invalid("The settings folder must be a regular folder owned by the current user.")
        }
        let staging = directory.appendingPathComponent(".settings-stage-\(UUID().uuidString).json")
        var descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            try? FileManager.default.removeItem(at: staging)
        }
        // fchmod fixes a restrictive process umask before publication; the file
        // is never created with group/other permissions in the first place.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, base.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw CornerActionError.invalid("The settings write could not make progress.") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        let finished = descriptor; descriptor = -1
        guard close(finished) == 0 else { throw posixError() }
        guard try readExisting() == existing else {
            throw CornerActionError.invalid("Saved settings changed during the write. The existing file has been preserved.")
        }
        try publish(staging, file)
    }
    /// Preserve an unreadable configuration before the user's explicit reset.
    func preserveForReset() throws -> URL? {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        let backup = directory.appendingPathComponent("settings-preserved-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: file, to: backup)
        return backup
    }
    private struct Snapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Data
    }
    private func readExisting() throws -> Snapshot? {
        guard directory.isFileURL else { throw CornerActionError.invalid("Settings require a local folder.") }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
              metadata.st_size >= 0, metadata.st_size <= 262_144 else {
            throw CornerActionError.invalid("The saved settings file is not a supported user-owned regular file. It has been preserved.")
        }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        guard opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else {
            throw CornerActionError.invalid("The settings path changed while it was being read. It has been preserved.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 262_145) ?? Data()
        var finished = stat()
        guard fstat(descriptor, &finished) == 0 else { throw posixError() }
        guard bytes.count <= 262_144, Int64(bytes.count) == opened.st_size, opened.st_size == finished.st_size else {
            throw CornerActionError.invalid("The settings file changed or exceeded its limit while being read. It has been preserved.")
        }
        return .init(device: UInt64(truncatingIfNeeded: opened.st_dev), inode: UInt64(opened.st_ino), bytes: bytes)
    }
    private static func atomicPublish(_ staging: URL, _ destination: URL) throws {
        guard rename(staging.path, destination.path) == 0 else { throw posixError() }
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func posixError() -> NSError { Self.posixError() }
}
