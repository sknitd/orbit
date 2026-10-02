import Foundation
import OrbitCore

struct ArchiveEngine: ActionEngine {
    func perform(_ action: ActionID, items: [FileItem], context: ActionContext) async throws -> ActionResult {
        guard action == .zip || action == .unzip else {
            throw OrbitError.unsupported("This archive action is not available.")
        }
        guard !items.isEmpty else { throw OrbitError.invalidInput("Choose a file or folder first.") }
        var outputs: [URL] = []
        var inputBytes: Int64 = 0
        var outputBytes: Int64 = 0
        do {
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                context.progress(Double(index) / Double(items.count), action == .zip ? "Creating ZIP…" : "Inspecting ZIP…")
                let sourceBytes = try ArchiveSafety.inspectTree(item.url, enforceArchiveNames: action == .zip)
                inputBytes += sourceBytes
                let stem = action == .zip ? item.url.lastPathComponent : item.url.deletingPathExtension().lastPathComponent
                let transaction = try OutputTransaction(source: item.url, outputDirectory: context.outputDirectory,
                                                       stem: stem, extension: action == .zip ? "zip" : "")
                defer { transaction.cleanup() }
                let logURL = transaction.stagingURL.deletingLastPathComponent().appendingPathComponent("process.log")
                if action == .zip {
                    let isDirectory = try item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    try transaction.preflight(expectedBytes: sourceBytes * (isDirectory ? 1 : 2))
                    var arguments = ["-c", "-k", "--norsrc", "--noextattr"]
                    let archiveSource: URL
                    if isDirectory {
                        archiveSource = item.url
                        arguments.append("--keepParent")
                    } else {
                        // ditto's ZIP interface archives directories. A private
                        // one-file directory makes the entry basename explicit
                        // and snapshots the bytes that will be compressed.
                        let sourceDirectory = transaction.stagingURL.deletingLastPathComponent()
                            .appendingPathComponent("archive-input", isDirectory: true)
                        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])
                        let snapshot = sourceDirectory.appendingPathComponent(item.url.lastPathComponent)
                        try FileManager.default.copyItem(at: item.url, to: snapshot)
                        let snapshotValues = try snapshot.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard snapshotValues.isRegularFile == true, snapshotValues.isSymbolicLink != true else {
                            throw OrbitError.invalidInput("Links and special files cannot be archived.")
                        }
                        archiveSource = sourceDirectory
                    }
                    arguments.append(contentsOf: [archiveSource.path, transaction.stagingURL.path])
                    try await ArchiveProcess.run(arguments: arguments, logURL: logURL)
                    _ = try ZIPInspector.inspect(transaction.stagingURL)
                    try await ArchiveProcess.run(executable: "/usr/bin/unzip", arguments: ["-t", "-qq", transaction.stagingURL.path], logURL: logURL)
                    let finalURL = try transaction.commit { zip in _ = try ZIPInspector.inspect(zip) }
                    outputs.append(finalURL)
                    outputBytes += Int64(try finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                } else {
                    let sourceProperties = try item.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard sourceProperties.isRegularFile == true, sourceProperties.isSymbolicLink != true else {
                        throw OrbitError.invalidInput("Choose a regular ZIP file to extract.")
                    }
                    // Vet exactly the bytes ditto will read. The source may be
                    // changed by another application without changing this snapshot.
                    let snapshot = transaction.stagingURL.deletingLastPathComponent().appendingPathComponent("archive.zip")
                    try FileManager.default.copyItem(at: item.url, to: snapshot)
                    let snapshotProperties = try snapshot.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard snapshotProperties.isRegularFile == true, snapshotProperties.isSymbolicLink != true else {
                        throw OrbitError.invalidInput("Symbolic-link archives cannot be extracted.")
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: snapshot.path)
                    let inventory = try ZIPInspector.inspect(snapshot)
                    try transaction.preflight(expectedBytes: inventory.expandedBytes)
                    try FileManager.default.createDirectory(at: transaction.stagingURL, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    context.progress((Double(index) + 0.25) / Double(items.count), "Extracting ZIP…")
                    try await ArchiveProcess.run(arguments: ["-x", "-k", "--norsrc", "--noextattr",
                                                              snapshot.path, transaction.stagingURL.path], logURL: logURL,
                                                 extractionRoot: transaction.stagingURL, expectedExpandedBytes: inventory.expandedBytes)
                    let finalURL = try transaction.commit { folder in
                        let expandedBytes = try ArchiveSafety.inspectTree(folder, enforceArchiveNames: true, normalizePermissions: true)
                        guard expandedBytes <= inventory.expandedBytes else {
                            throw OrbitError.invalidInput("ZIP extraction exceeded its verified size limits.")
                        }
                    }
                    outputs.append(finalURL)
                    outputBytes += try ArchiveSafety.inspectTree(finalURL, enforceArchiveNames: false)
                }
            }
            try Task.checkCancellation()
            context.progress(1, "Saved")
            return ActionResult(outputs: outputs, inputBytes: inputBytes, outputBytes: outputBytes)
        } catch {
            // Roll back only outputs published by this invocation. The atomic
            // transaction never replaced an input or preexisting result.
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }
}

private enum ArchiveSafety {
    static func inspectTree(_ root: URL, enforceArchiveNames: Bool, normalizePermissions: Bool = false) throws -> Int64 {
        guard root.isFileURL else { throw OrbitError.invalidInput("Archives require local files.") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true || rootValues.isRegularFile == true else {
            throw OrbitError.invalidInput("Links and special files cannot be archived.")
        }
        if enforceArchiveNames { _ = try ZIPInspector.safePath(root.lastPathComponent) }
        if rootValues.isRegularFile == true {
            let bytes = Int64(rootValues.fileSize ?? 0)
            guard bytes <= ZIPInspector.maximumExpandedBytes else { throw OrbitError.invalidInput("The archive exceeds the 2 GB safety limit.") }
            return bytes
        }
        // Reject a symbolic-link source above, then resolve only its parent
        // aliases before enumeration. FileManager may canonicalize child URLs,
        // so lexical paths through an alias are not a containment boundary.
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: Array(keys), options: [],
                                                              errorHandler: { _, error in enumerationError = error; return false }) else {
            throw OrbitError.failed("Couldn’t read the folder contents.")
        }
        let canonicalPrefix = canonicalRoot.path + "/"
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= ZIPInspector.maximumEntries * 4 else { throw OrbitError.invalidInput("The folder contains too many entries.") }
            let values = try url.resourceValues(forKeys: keys)
            let canonicalChild = url.standardizedFileURL.resolvingSymlinksInPath()
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true,
                  canonicalChild.path.hasPrefix(canonicalPrefix) else {
                throw OrbitError.invalidInput("The folder contains a link, special file, or unsafe path.")
            }
            if enforceArchiveNames {
                _ = try ZIPInspector.safePath(String(canonicalChild.path.dropFirst(canonicalPrefix.count)))
            }
            bytes += Int64(values.fileSize ?? 0) * (values.isRegularFile == true ? 1 : 0)
            guard bytes <= ZIPInspector.maximumExpandedBytes else { throw OrbitError.invalidInput("The archive exceeds the 2 GB safety limit.") }
            if normalizePermissions {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let executable = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let permissions = values.isDirectory == true ? 0o700 : 0o600 | (executable & 0o100)
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        }
        if let enumerationError { throw enumerationError }
        if normalizePermissions { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        return bytes
    }

    /// ZIP size fields can lie. Stop a running extraction if actual writes
    /// exceed the declared total, per-file quota, or supported entry count.
    static func monitorExpansion(at root: URL, expectedBytes: Int64) throws {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            throw OrbitError.failed("Couldn’t monitor ZIP extraction.")
        }
        var bytes: Int64 = 0
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= ZIPInspector.maximumEntries * 4 else {
                throw OrbitError.invalidInput("ZIP extraction exceeded the entry limit.")
            }
            // A member may disappear while ditto updates it; retry the full
            // tree on the next pass rather than misclassifying that race.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            guard values.isSymbolicLink != true else { throw OrbitError.invalidInput("A ZIP entry created a symbolic link.") }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                bytes += size
                guard size <= Int64(ZIPInspector.maximumEntryBytes), bytes <= expectedBytes else {
                    throw OrbitError.invalidInput("ZIP extraction exceeded its verified size limits.")
                }
            }
        }
    }
}

private final class ArchiveProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    private func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw OrbitError.cancelled }
        try process.run()
    }
    private func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
    private var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    static func run(executable: String = "/usr/bin/ditto", arguments: [String], logURL: URL, extractionRoot: URL? = nil, expectedExpandedBytes: Int64 = 0) async throws {
        let runner = ArchiveProcess()
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw OrbitError.failed("Couldn’t create a private archive diagnostic file.")
        }
        let diagnostic = try FileHandle(forWritingTo: logURL)
        defer { try? diagnostic.close() }
        runner.process.executableURL = URL(fileURLWithPath: executable)
        runner.process.arguments = arguments
        runner.process.standardInput = FileHandle.nullDevice
        runner.process.standardOutput = FileHandle.nullDevice
        runner.process.standardError = diagnostic
        if let extractionRoot {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await runner.wait(logURL: logURL) }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        try ArchiveSafety.monitorExpansion(at: extractionRoot, expectedBytes: expectedExpandedBytes)
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                do { _ = try await group.next() }
                catch { group.cancelAll(); runner.cancel(); throw error }
                group.cancelAll()
            }
        } else {
            try await runner.wait(logURL: logURL)
        }
    }

    private func wait(logURL: URL) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    // Process retains its handler; release the handler's
                    // capture of this runner once the child has exited.
                    process.terminationHandler = nil
                    if self.wasCancelled { continuation.resume(throwing: OrbitError.cancelled) }
                    else if process.terminationStatus == 0 { continuation.resume() }
                    else {
                        let reader = try? FileHandle(forReadingFrom: logURL)
                        let data = try? reader?.read(upToCount: 4_096)
                        try? reader?.close()
                        let details = data.flatMap { String(data: $0, encoding: .utf8) }?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: OrbitError.failed(details?.isEmpty == false ? "Couldn’t process ZIP: \(details!)" : "The system ZIP utility could not process this file."))
                    }
                }
                do { try self.launch() }
                catch {
                    self.process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }
}
