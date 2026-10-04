import Foundation
import CornerCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum CornerProfileExport {
    /// NSSavePanel supplies an explicitly selected destination; final publication
    /// is atomic, with private mode established while the file is still staging.
    static func write(_ bytes: Data, to destination: URL) throws {
        guard destination.isFileURL, bytes.count <= CornerProfileValidation.maximumBytes else { throw CornerActionError.invalid("Choose a local export destination for at most 2 MiB of profile JSON.") }
        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), existing.st_uid == getuid() else { throw CornerActionError.invalid("The export destination must be a regular file owned by you.") }
        } else if errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".CornerOrbit-export-\(UUID().uuidString).json")
        var descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { if descriptor >= 0 { _ = close(descriptor) }; try? FileManager.default.removeItem(at: staging) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }; var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, start.advanced(by: offset), buffer.count - offset)
                #else
                let count = Glibc.write(descriptor, start.advanced(by: offset), buffer.count - offset)
                #endif
                if count < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                guard count > 0 else { throw CornerActionError.invalid("The export write could not make progress.") }; offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let finished = descriptor; descriptor = -1
        guard close(finished) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var current = stat()
        let existsNow = lstat(destination.path, &current) == 0
        if existing.st_ino != 0 {
            guard existsNow, current.st_dev == existing.st_dev, current.st_ino == existing.st_ino else { throw CornerActionError.invalid("The export destination changed during the write and was preserved.") }
        } else {
            guard !existsNow, errno == ENOENT else { throw CornerActionError.invalid("The export destination appeared during the write and was preserved.") }
        }
        guard rename(staging.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
