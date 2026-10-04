import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import OrbitCore
import NotchCore

enum WorkflowError: Error, LocalizedError, Sendable {
    case sourceChanged(String)
    var errorDescription: String? {
        switch self { case .sourceChanged(let name): "\(name) changed during the workflow. No workflow output was kept; drop the current file again." }
    }
}

/// Every stage runs against owned snapshots. Nothing is published until the
/// entire chain and original-content checks succeed; rollback owns only the
/// outputs of this invocation and never writes to any dropped source.
struct WorkflowRunner: Sendable {
    static func perform(preset: WorkflowPreset, urls: [URL], outputDirectory: URL? = nil,
                        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> ActionResult {
        let work = Task.detached(priority: .userInitiated) {
            try await process(preset: preset, urls: urls, outputDirectory: outputDirectory, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private struct Snapshot: Sendable {
        let source: URL
        let copy: URL
        let hash: Data
        let bytes: Int64
    }
    private static func process(preset raw: WorkflowPreset, urls: [URL], outputDirectory: URL?,
                                progress: @escaping @Sendable (Double, String) -> Void) async throws -> ActionResult {
        let preset = try raw.validated()
        guard (1...64).contains(urls.count),
              Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).count == urls.count,
              NotchDragPayload.matches(observed: urls, dropped: urls),
              outputDirectory.map({ NotchDragPayload.matches(observed: [$0], dropped: [$0]) }) ?? true else {
            throw OrbitError.invalidInput("Drop 1–64 distinct local files into the saved workflow.")
        }
        let originalItems = try FileInspector.inspect(urls)
        let needsImages = !preset.isVideoWorkflow && preset.steps.contains { $0 != .zip }
        guard originalItems.count == urls.count,
              originalItems.allSatisfy({ preset.isVideoWorkflow ? $0.kind == .video : needsImages ? $0.kind == .image : $0.kind != .folder }) else {
            throw OrbitError.invalidInput(preset.isVideoWorkflow ? "This workflow needs video files only, such as MOV or MP4." : needsImages ? "This workflow needs still images only." : "Drop regular files, not folders, into this workflow.")
        }
        guard originalItems.allSatisfy({ $0.byteCount <= 512 * 1024 * 1024 }),
              originalItems.reduce(0, { $0 + $1.byteCount }) <= 2 * 1024 * 1024 * 1024 else {
            throw OrbitError.unsupported("Workflows support up to 512 MB per file and 2 GB per batch.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-Workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var published: [URL] = []
        do {
            let inputs = try directory("inputs", in: root)
            var snapshots: [Snapshot] = []
            for (index, item) in originalItems.enumerated() {
                try Task.checkCancellation()
                let ext = item.url.pathExtension.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
                let copy = inputs.appendingPathComponent("input-\(index + 1)" + (ext.isEmpty ? "" : "." + String(ext.prefix(20))))
                let captured = try snapshot(item.url, to: copy)
                guard snapshots.reduce(0, { $0 + $1.bytes }) + captured.bytes <= 2 * 1024 * 1024 * 1024 else {
                    throw OrbitError.unsupported("Workflow inputs grew beyond the 2 GB batch limit.")
                }
                snapshots.append(Snapshot(source: item.url, copy: copy, hash: captured.hash, bytes: captured.bytes))
            }
            var current = snapshots.map(\.copy)
            for (index, step) in preset.steps.enumerated() {
                try Task.checkCancellation()
                let output = try directory("step-\(index + 1)", in: root)
                let stepProgress: @Sendable (Double, String) -> Void = { fraction, message in
                    progress((Double(index) + max(0, min(1, fraction))) / Double(preset.steps.count + 1), message)
                }
                switch step {
                case .resize(let maximum):
                    current = try resize(current, maximum: maximum, directory: output, progress: stepProgress)
                case .convert(let format):
                    let action: ActionID = switch format { case .jpeg: .jpeg; case .png: .png; case .heic: .heic; case .webp: .webp }
                    let result = try await ImageEngine().perform(action, items: FileInspector.inspect(current),
                                                                 context: .init(outputDirectory: output, quality: 1, progress: stepProgress))
                    current = result.outputs
                case .compress(let quality):
                    let result = try await ImageEngine().perform(.compressImage, items: FileInspector.inspect(current),
                                                                 context: .init(outputDirectory: output, quality: quality, progress: stepProgress))
                    current = result.outputs
                case .compressVideo:
                    let result = try await NativeMediaEngine().perform(.compressVideo, items: FileInspector.inspect(current),
                                                                      context: .init(outputDirectory: output, progress: stepProgress))
                    current = result.outputs
                case .zip:
                    let bundle = try directory(preset.name, in: output)
                    for (position, url) in current.enumerated() {
                        try Task.checkCancellation()
                        _ = try publishCopy(url, source: snapshots[position].source, directory: bundle,
                                            stem: outputStem(source: snapshots[position].source, preset: preset))
                    }
                    let result = try await ArchiveEngine().perform(.zip, items: FileInspector.inspect([bundle]),
                                                                   context: .init(outputDirectory: output, progress: stepProgress))
                    current = result.outputs
                }
                progress(Double(index + 1) / Double(preset.steps.count + 1), "Step \(index + 1) complete")
                try Task.checkCancellation()
            }
            progress(0.95, "Verifying original files…")
            try verifyOriginals(snapshots)
            for (index, url) in current.enumerated() {
                try Task.checkCancellation()
                let zipped = preset.steps.last == .zip
                let source = snapshots[zipped ? 0 : index].source
                let stem = zipped ? preset.name : outputStem(source: source, preset: preset)
                published.append(try publishCopy(url, source: source, directory: outputDirectory, stem: stem))
            }
            try Task.checkCancellation()
            try verifyOriginals(snapshots)
            let result = ActionResult(outputs: published, inputBytes: snapshots.reduce(0) { $0 + $1.bytes },
                                      outputBytes: try ImageEngine.totalBytes(published))
            progress(1, "Workflow saved")
            return result
        } catch {
            for output in published { try? FileManager.default.removeItem(at: output) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    private static func directory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private static func outputStem(source: URL, preset: WorkflowPreset) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = source.deletingPathExtension().lastPathComponent.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        var short = cleaned
        while short.utf8.count > 90 { short.removeLast() }
        return (short.isEmpty ? "image" : short) + "-" + preset.name
    }
    private static func publishCopy(_ staged: URL, source: URL, directory: URL?, stem: String) throws -> URL {
        try OutputTransaction.write(source: source, outputDirectory: directory, stem: stem, extension: staged.pathExtension,
                                    writer: { destination in
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: staged, to: destination)
            try Task.checkCancellation()
        }, validate: { destination in
            guard try digest(destination) == digest(staged) else { throw OrbitError.failed("Workflow output did not pass verification.") }
        })
    }
    private static func verifyOriginals(_ inputs: [Snapshot]) throws {
        for input in inputs {
            try Task.checkCancellation()
            let values = try? input.source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw WorkflowError.sourceChanged(input.source.lastPathComponent)
            }
            let hash: Data
            do { hash = try digest(input.source) }
            catch let cancellation as CancellationError { throw cancellation }
            catch { throw WorkflowError.sourceChanged(input.source.lastPathComponent) }
            guard hash == input.hash else { throw WorkflowError.sourceChanged(input.source.lastPathComponent) }
        }
    }
    private static func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return Data(hash.finalize())
    }
    private static func snapshot(_ source: URL, to destination: URL) throws -> (bytes: Int64, hash: Data) {
        // Open the real regular file once. A source replaced by a symbolic link
        // after inspection is rejected rather than followed during the copy.
        let descriptor = source.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw OrbitError.invalidInput("Could not snapshot \(source.lastPathComponent). Drop the current regular file again.") }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var values = stat()
        guard fstat(descriptor, &values) == 0, UInt32(values.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else {
            throw OrbitError.invalidInput("Workflows require regular files, not links or special files.")
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw OrbitError.failed("Could not create the private workflow snapshot.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hash = SHA256(); var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            count += Int64(bytes.count)
            guard count <= 512 * 1024 * 1024 else { throw OrbitError.unsupported("Each workflow input must be at most 512 MB.") }
            try output.write(contentsOf: bytes); hash.update(data: bytes)
        }
        return (count, Data(hash.finalize()))
    }
    private static func resize(_ urls: [URL], maximum: Int, directory: URL,
                               progress: @Sendable (Double, String) -> Void) throws -> [URL] {
        try urls.enumerated().map { index, url in
            try Task.checkCancellation()
            progress(Double(index) / Double(urls.count), "Resizing \(index + 1) of \(urls.count)…")
            return try autoreleasepool {
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                   let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                   let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber {
                    let w = width.doubleValue, h = height.doubleValue
                    let scale = min(1, Double(maximum) / max(w, h))
                    guard w.isFinite, h.isFinite, w > 0, h > 0,
                          ceil(w * scale) * ceil(h * scale) <= 40_000_000 else {
                        throw OrbitError.unsupported("Choose a smaller workflow dimension; the resized image exceeds 40 million pixels.")
                    }
                }
                let image = try ImageEngine.loadUpright(url, maxPixelSize: maximum)
                return try OutputTransaction.write(source: url, outputDirectory: directory,
                                                   stem: "image-\(index + 1)-resized", extension: "png", writer: { destination in
                    guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                        throw OrbitError.failed("Could not prepare the resized image.")
                    }
                    let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                    var properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
                    properties[kCGImagePropertyOrientation as String] = 1
                    properties[kCGImagePropertyPixelWidth as String] = image.width
                    properties[kCGImagePropertyPixelHeight as String] = image.height
                    if var tags = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                        tags[kCGImagePropertyTIFFOrientation as String] = 1
                        properties[kCGImagePropertyTIFFDictionary as String] = tags
                    }
                    if var tags = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                        tags[kCGImagePropertyExifPixelXDimension as String] = image.width
                        tags[kCGImagePropertyExifPixelYDimension as String] = image.height
                        properties[kCGImagePropertyExifDictionary as String] = tags
                    }
                    CGImageDestinationAddImage(writer, image, properties as CFDictionary)
                    guard CGImageDestinationFinalize(writer) else { throw OrbitError.failed("Image resizing did not finish.") }
                    try Task.checkCancellation()
                }, validate: { try ImageEngine.verifyImage($0, expectedWidth: image.width, expectedHeight: image.height) })
            }
        }
    }
}
