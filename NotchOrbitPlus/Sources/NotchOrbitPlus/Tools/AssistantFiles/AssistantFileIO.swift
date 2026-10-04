import Foundation
import CryptoKit
import Darwin
import PDFKit
import Vision
import ImageIO
import OrbitCore
import NotchCore

struct AssistantNamedProposal: Identifiable, Sendable {
    let id = UUID()
    let document: AssistantFileDocument
    var response: String
}
struct AssistantOwnedCopy: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let output: URL
    let digest: Data
    let device: UInt64
    let inode: UInt64
}

enum AssistantFileIO {
    static func read(_ source: URL, action: AssistantFileAction) throws -> AssistantFileDocument {
        try Task.checkCancellation()
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        _ = try identity(source)
        let originalDigest = try digest(source)
        let text: String
        if action == .renameScreenshots {
            guard let decoder = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(decoder) > 0 else {
                throw AssistantFileFailure.invalid("Screenshot naming needs readable image files.")
            }
            let image = try ImageEngine.loadUpright(source, maxPixelSize: 2_048)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } else if source.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0,
                  document.pageCount <= 2_000 else { throw AssistantFileFailure.invalid("Choose an unlocked, nonempty PDF of at most 2,000 pages.") }
            var pages = ""
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                pages += String((document.page(at: index)?.string ?? "").prefix(AssistantFilePlanning.maximumTextCharacters)) + "\n"
                if pages.count >= AssistantFilePlanning.maximumTextCharacters { break }
            }
            text = pages
        } else {
            guard ["txt", "md", "markdown", "csv", "json", "log"].contains(source.pathExtension.lowercased()) else {
                throw AssistantFileFailure.invalid("Choose a UTF-8 text, Markdown, CSV, JSON or PDF file; screenshot naming accepts images.")
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var bytes = try handle.read(upToCount: 256_000) ?? Data()
            var decoded = String(data: bytes, encoding: .utf8)
            for _ in 0..<3 where decoded == nil && !bytes.isEmpty {
                bytes.removeLast(); decoded = String(data: bytes, encoding: .utf8)
            }
            guard let decoded else { throw AssistantFileFailure.invalid("The text file needs UTF-8 encoding.") }
            text = decoded
        }
        try Task.checkCancellation()
        guard try digest(source) == originalDigest else { throw AssistantFileFailure.invalid("The file changed during inspection. Drop its current version again.") }
        return AssistantFileDocument(source: source, text: try AssistantFilePlanning.boundedText(text), sourceDigest: originalDigest)
    }
    static func createNamedCopies(_ proposals: [AssistantNamedProposal]) throws -> [AssistantOwnedCopy] {
        var owned: [AssistantOwnedCopy] = []
        do {
            for proposal in proposals {
                try Task.checkCancellation()
                let source = proposal.document.source
                let granted = source.startAccessingSecurityScopedResource()
                defer { if granted { source.stopAccessingSecurityScopedResource() } }
                let stem = try AssistantFilePlanning.filenameStem(proposal.response)
                guard try digest(source) == proposal.document.sourceDigest else {
                    throw AssistantFileFailure.invalid("\(source.lastPathComponent) changed after its preview. Generate a new proposal.")
                }
                let output = try OutputTransaction.write(source: source, outputDirectory: nil, stem: stem, extension: source.pathExtension,
                    writer: { destination in
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: source, to: destination)
                    }, validate: { destination in
                        guard try digest(destination) == proposal.document.sourceDigest else {
                            throw AssistantFileFailure.invalid("The named copy did not match the original preview.")
                        }
                    })
                let identifier = try identity(output)
                owned.append(.init(source: source, output: output, digest: proposal.document.sourceDigest,
                                   device: identifier.device, inode: identifier.inode))
                try Task.checkCancellation()
            }
            return owned
        } catch {
            _ = undo(owned)
            throw error
        }
    }
    /// Refuses originals, links, replaced files, and copies edited since publication.
    /// The returned records are retained so a failed or modified output remains visible.
    static func undo(_ owned: [AssistantOwnedCopy]) -> [AssistantOwnedCopy] {
        owned.filter { record in
            do {
                let canonicalSource = record.source.standardizedFileURL.resolvingSymlinksInPath()
                let canonicalOutput = record.output.standardizedFileURL.resolvingSymlinksInPath()
                guard canonicalSource != canonicalOutput,
                      canonicalSource.deletingLastPathComponent() == canonicalOutput.deletingLastPathComponent() else { return true }
                guard FileManager.default.fileExists(atPath: record.output.path) else { return false }
                let identifier = try identity(record.output)
                guard identifier.device == record.device, identifier.inode == record.inode,
                      try digest(record.output, checkCancellation: false) == record.digest else { return true }
                let final = try identity(record.output)
                guard final.device == record.device, final.inode == record.inode else { return true }
                try FileManager.default.removeItem(at: record.output)
                return false
            } catch { return true }
        }
    }
    static func digest(_ source: URL, checkCancellation: Bool = true) throws -> Data {
        _ = try identity(source)
        let descriptor = source.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw AssistantFileFailure.invalid("Could not read the regular local file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256(); var bytes = 0
        while let part = try handle.read(upToCount: 1_048_576), !part.isEmpty {
            if checkCancellation { try Task.checkCancellation() }
            bytes += part.count
            guard bytes <= 50 * 1_024 * 1_024 else { throw AssistantFileFailure.invalid("Each file action input is limited to 50 MB.") }
            hash.update(data: part)
        }
        return Data(hash.finalize())
    }
    private static func identity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost" else { throw AssistantFileFailure.invalid("Choose regular local files.") }
        var values = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &values) } ?? -1 }
        guard result == 0, UInt32(values.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
              values.st_size >= 0, values.st_size <= 50 * 1_024 * 1_024 else { throw AssistantFileFailure.invalid("Choose a regular file of at most 50 MB; symbolic links are excluded.") }
        return (UInt64(UInt32(bitPattern: values.st_dev)), UInt64(values.st_ino))
    }
}
