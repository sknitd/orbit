import Foundation
import OrbitCore
import Darwin

/// Writes into a private sibling directory, then publishes with an exclusive
/// rename. A competing writer can never replace an existing result or input.
final class OutputTransaction {
    let stagingURL: URL
    private let temporaryDirectory: URL
    private let destinationDirectory: URL
    private let stem: String
    private let fileExtension: String
    private var committed = false

    init(source: URL, outputDirectory: URL?, stem: String, extension fileExtension: String) throws {
        guard source.isFileURL, outputDirectory?.isFileURL != false else {
            throw OrbitError.invalidInput("Choose a local file and output folder.")
        }
        try Self.validateName(stem: stem, extension: fileExtension)
        self.stem = stem
        self.fileExtension = fileExtension
        destinationDirectory = (outputDirectory ?? source.deletingLastPathComponent())
            .standardizedFileURL.resolvingSymlinksInPath()
        let properties = try destinationDirectory.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard properties.isDirectory == true else {
            throw OrbitError.invalidInput("The output folder does not exist.")
        }
        guard properties.isWritable != false else {
            throw OrbitError.failed("The output folder is read-only. Choose another folder in Settings.")
        }
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let sourceBytes = sourceValues.isDirectory == true ? 0 : Int64(sourceValues.fileSize ?? 0)
        try Self.checkCapacity(in: destinationDirectory, bytes: sourceBytes)

        let privateDirectory = destinationDirectory.appendingPathComponent(".orbitdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        temporaryDirectory = privateDirectory
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        stagingURL = privateDirectory.appendingPathComponent("output\(suffix)")
    }

    /// Engines with a known expanded/transcoded size can make a stronger check.
    func preflight(expectedBytes: Int64) throws {
        try Self.checkCapacity(in: destinationDirectory, bytes: expectedBytes)
    }

    func commit(validate: (URL) throws -> Void) throws -> URL {
        guard !committed else { throw OrbitError.failed("This output has already been saved.") }
        try Task.checkCancellation()
        let values = try stagingURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true || values.isDirectory == true else {
            throw OrbitError.failed("The operation did not produce a valid output.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        let existingMode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let privateMode = values.isDirectory == true ? 0o700 : 0o600 | (existingMode & 0o100)
        try FileManager.default.setAttributes([.posixPermissions: privateMode], ofItemAtPath: stagingURL.path)
        try validate(stagingURL)
        try Task.checkCancellation()
        for suffix in 1...10_000 {
            let numberedStem = suffix == 1 ? stem : "\(stem) (\(suffix))"
            let filename = fileExtension.isEmpty ? numberedStem : "\(numberedStem).\(fileExtension)"
            let finalURL = destinationDirectory.appendingPathComponent(filename)
            let result = stagingURL.withUnsafeFileSystemRepresentation { from in
                finalURL.withUnsafeFileSystemRepresentation { to in
                    renamex_np(from, to, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                committed = true
                cleanup()
                return finalURL
            }
            let failure = errno
            if failure == EEXIST || failure == ENOTEMPTY { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t save the output: \(String(cString: strerror(failure)))."
            ])
        }
        throw OrbitError.failed("Too many outputs have this name. Choose another output folder.")
    }

    func cleanup() {
        // The UUID directory is owned by this transaction; final outputs are
        // outside it and are never included in cleanup.
        // Malformed archives may request unreadable directory permissions.
        // Restore traversal on our private directories before removing them;
        // symbolic links are neither traversed nor chmod-ed.
        if let children = FileManager.default.enumerator(at: temporaryDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) {
            for case let child as URL in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            }
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    deinit { cleanup() }

    static func write(source: URL, outputDirectory: URL?, stem: String, extension fileExtension: String,
                      writer: (URL) throws -> Void, validate: (URL) throws -> Void) throws -> URL {
        let transaction = try OutputTransaction(source: source, outputDirectory: outputDirectory,
                                               stem: stem, extension: fileExtension)
        defer { transaction.cleanup() }
        try writer(transaction.stagingURL)
        return try transaction.commit(validate: validate)
    }

    private static func validateName(stem: String, extension fileExtension: String) throws {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        guard !stem.isEmpty, stem != ".", stem != "..", stem.utf8.count <= 200,
              stem.rangeOfCharacter(from: forbidden) == nil,
              fileExtension.utf8.count <= 20,
              fileExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
              stem.utf8.count + fileExtension.utf8.count <= 220 else {
            throw OrbitError.invalidInput("The output filename is invalid or too long.")
        }
    }

    private static func checkCapacity(in directory: URL, bytes: Int64) throws {
        guard bytes >= 0, bytes <= Int64.max - 1_048_576 else {
            throw OrbitError.invalidInput("The requested output is too large.")
        }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
        if let available, available < bytes + 1_048_576 {
            throw OrbitError.failed("There isn’t enough free space in the output folder.")
        }
    }
}
