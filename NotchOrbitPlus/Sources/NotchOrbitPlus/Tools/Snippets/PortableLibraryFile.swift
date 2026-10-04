import Foundation
import NotchCore

enum PlusPortableLibraryFile {
    static func load<Value>(at url: URL, limit: Int, decode: (Data) throws -> Value) throws -> Value? {
        guard try PlusSyncFolderIO.hasNode(url) else { return nil }
        return try decode(PlusSyncFolderIO.boundedData(url, limit: limit))
    }
    static func save<Value>(_ data: Data, at url: URL, limit: Int, decode: (Data) throws -> Value) throws {
        _ = try load(at: url, limit: limit, decode: decode)
        guard data.count <= limit else { throw SyncFailure.invalid("The local library exceeds its size limit.") }
        try data.write(to: url, options: .atomic)
        // The enclosing LocalTools directory is private; do not report failure after publication for an attribute-only error.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func backupAndRemove(_ url: URL) throws {
        guard try PlusSyncFolderIO.hasNode(url) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString).backup")
        try FileManager.default.copyItem(at: url, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try FileManager.default.removeItem(at: url)
    }
}
