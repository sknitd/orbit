import Foundation
import AppKit
import Darwin
import CornerCore

@MainActor
protocol CornerClipboardReading {
    func readPlainText() throws -> String
}

@MainActor
struct CornerNativeClipboardReader: CornerClipboardReading {
    func readPlainText() throws -> String {
        try Task.checkCancellation()
        guard let text = NSPasteboard.general.string(forType: .string) else {
            throw CornerActionError.invalid("The clipboard does not contain plain text.")
        }
        return try CornerClipboardActionText.bounded(text)
    }
}

protocol CornerDraftWriting: Sendable {
    func create(text: String) async throws -> URL
}

struct CornerTextDraftWriter: CornerDraftWriting {
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    func create(text: String) async throws -> URL {
        let text = try CornerClipboardActionText.bounded(text)
        let work = Task.detached(priority: .userInitiated) { try write(text: text) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func write(text: String) throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        let folder: URL
        if let directory { folder = directory }
        else {
            guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CornerActionError.invalid("The application-support folder is unavailable.")
            }
            folder = support.appendingPathComponent("com.sknitd.CornerOrbit", isDirectory: true).appendingPathComponent("Drafts", isDirectory: true)
        }
        // A manipulated application-owned final directory is rejected, not followed.
        for candidate in [folder.deletingLastPathComponent(), folder] {
            if manager.fileExists(atPath: candidate.path) {
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CornerActionError.invalid("The CornerOrbit drafts folder is not a regular local directory.")
                }
            }
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        let identifier = UUID().uuidString
        let temporary = folder.appendingPathComponent(".draft-" + identifier)
        let result = folder.appendingPathComponent("Clipboard-" + identifier + ".txt")
        let descriptor = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw CornerActionError.invalid("The private clipboard draft could not be created exclusively.") }
        defer { try? manager.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: Data(text.utf8)); try handle.close() }
        catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        try manager.moveItem(at: temporary, to: result)
        if Task.isCancelled { try? manager.removeItem(at: result); throw CancellationError() }
        return result
    }
}
