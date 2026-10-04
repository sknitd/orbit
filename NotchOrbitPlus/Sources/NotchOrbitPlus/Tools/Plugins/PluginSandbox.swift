import Foundation
import Darwin
import NotchCore

struct PlusPluginPackage: Sendable {
    let manifest: CorePluginManifest
    let scripts: [String: Data]
}
struct PlusPluginProcessFailure: LocalizedError, Sendable {
    let status: Int32
    let terminatedBySignal: Bool
    let processID: Int32
    let diagnostic: String
    var errorDescription: String? {
        let cause = terminatedBySignal ? "signal \(status)" : "status \(status)"
        let detail = diagnostic.isEmpty ? "" : "\nSandbox diagnostic: \(diagnostic)"
        return "Plugin command or sandbox exited with \(cause). No output was applied.\(detail)"
    }
}
enum PlusPluginFolderIO {
    static func physicalPath(_ path: String) -> String? {
        guard let pointer = path.withCString({ Darwin.realpath($0, nil) }) else { return nil }
        defer { Darwin.free(pointer) }
        return String(cString: pointer)
    }
    static func physicalDirectoryPath(_ folder: URL) throws -> String {
        guard folder.isFileURL, let path = physicalPath(folder.path) else { throw CorePluginError.invalid("The chosen plugin folder is unavailable.") }
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CorePluginError.invalid("Plugin grants must refer to existing directories.") }
        Darwin.close(descriptor)
        return path
    }
    static func readRegistry(_ folder: URL) throws -> Data {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CorePluginError.invalid("Plugin storage is unavailable or is a symbolic link.") }
        defer { close(descriptor) }
        return try readFile("installed.json", directory: descriptor, limit: 4_194_304)
    }
    static func readPackage(_ folder: URL) throws -> PlusPluginPackage {
        guard folder.isFileURL else { throw CorePluginError.invalid("Choose a local plugin folder.") }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let canonical = try physicalDirectoryPath(folder)
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CorePluginError.invalid("The chosen plugin folder is unavailable.") }
        defer { close(descriptor) }
        let manifest = try CorePluginManifest.decode(readFile("manifest.json", directory: descriptor))
        var scripts: [String: Data] = [:]
        for command in manifest.commands { scripts[command.script] = try readFile(command.script, directory: descriptor) }
        return PlusPluginPackage(manifest: manifest, scripts: scripts)
    }
    private static func readFile(_ name: String, directory: Int32, limit: Int = 65_536) throws -> Data {
        guard name == "manifest.json" || CorePluginManifest.safeFilename(name) else { throw CorePluginError.invalid("Plugin path is invalid.") }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CorePluginError.invalid("A plugin file is missing or is a symbolic link.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
            throw CorePluginError.invalid("Plugin files must be regular files within the supported size limit.")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw CorePluginError.invalid("A plugin file could not be read.") }
            if count == 0 { break }
            guard data.count + count <= limit else { throw CorePluginError.invalid("A plugin file grew beyond the supported size limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

enum PlusPluginSandbox {
    static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    // Apple's sh implementation can dispatch/re-exec another interpreter.
    // Pick the POSIX interpreter explicitly so no selector access is needed.
    static let interpreter = URL(fileURLWithPath: "/bin/bash")
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path) && FileManager.default.isExecutableFile(atPath: interpreter.path)
    }
    static func profile(folder: URL, writable: Bool, readFolders: [URL]) throws -> String {
        guard folder.isFileURL, readFolders.count <= 4, readFolders.allSatisfy(\.isFileURL) else { throw CorePluginError.invalid("Invalid plugin folder grants.") }
        func literal(_ path: String) throws -> String {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CorePluginError.invalid("Folder path contains unsupported control characters.") }
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let folderPath = try PlusPluginFolderIO.physicalDirectoryPath(folder)
        let readPaths = try readFolders.map(PlusPluginFolderIO.physicalDirectoryPath)
        let root = try literal(folderPath)
        // Newer dyld loads the shared cache from the sealed OS cryptex.
        // Seatbelt checks the resolved Preboot path as well as its OS alias.
        let runtimeAliases = ["/System/Library", "/usr/lib", "/System/Cryptexes/OS/System/Library", "/System/Cryptexes/OS/usr/lib"]
        let runtimePaths = Set(runtimeAliases.flatMap { path in
            [path] + (PlusPluginFolderIO.physicalPath(path).map { [$0] } ?? [])
        }).sorted()
        let runtimeFilters = try runtimePaths.map { "(subpath \(try literal($0)))" }.joined(separator: " ")
        var metadataPaths: Set<String> = ["/", "/System/Cryptexes/OS"]
        for path in [folderPath] + readPaths + runtimePaths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                metadataPaths.insert(parent)
                if parent == "/" { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let metadataFilters = try metadataPaths.sorted().map { "(literal \(try literal($0)))" }.joined(separator: " ")
        var profile = """
        (version 1)
        (deny default)
        (allow process-exec (literal "/bin/bash"))
        (allow sysctl-read)
        (allow file-read-data (literal "/"))
        (allow file-read-metadata \(metadataFilters))
        (allow file-read* \(runtimeFilters) (literal "/bin/bash") (subpath \(root)))
        (allow file-map-executable \(runtimeFilters) (literal "/bin/bash"))
        """
        for path in readPaths { profile += "\n(allow file-read* (subpath \(try literal(path))))" }
        if writable { profile += "\n(allow file-write* (subpath \(root)))" }
        // No network, mach/Apple Events, device/clipboard access, process-fork,
        // or arbitrary runtime execution is granted. v1 uses shell builtins.
        return profile
    }
}

final class PlusPluginProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func run(folder: URL, command: CorePluginCommand, grants: Set<CorePluginPermission>, readFolders: [URL], clipboard: String?) async throws -> Data {
        guard PlusPluginSandbox.available else { throw CorePluginError.invalid("The macOS sandbox runner is unavailable. Plugin scripts are disabled on this Mac.") }
        let folderPath = try PlusPluginFolderIO.physicalDirectoryPath(folder)
        let readPaths = try readFolders.map(PlusPluginFolderIO.physicalDirectoryPath)
        let profile = try PlusPluginSandbox.profile(folder: URL(fileURLWithPath: folderPath, isDirectory: true), writable: grants.contains(.ownFolderWrite), readFolders: readPaths.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let work = Task.detached(priority: .userInitiated) { try self.execute(folderPath: folderPath, command: command, profile: profile, clipboard: clipboard, readPaths: readPaths) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { self.cancel(); work.cancel() }
    }
    private func execute(folderPath: String, command: CorePluginCommand, profile: String, clipboard: String?, readPaths: [String]) throws -> Data {
        try Task.checkCancellation()
        let child = Process(); let output = Pipe()
        child.executableURL = PlusPluginSandbox.executable
        child.arguments = ["-p", profile, PlusPluginSandbox.interpreter.path, "--noprofile", "--norc", "--posix", folderPath + "/" + command.script]
        child.currentDirectoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        var environment = ["PATH": "/nonexistent", "LC_ALL": "C", "ORBIT_PLUGIN_API": "1", "PWD": folderPath]
        if let clipboard { environment["ORBIT_CLIPBOARD"] = clipboard }
        for (index, path) in readPaths.enumerated() { environment["ORBIT_READ_FOLDER_\(index)"] = path }
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = output
        lock.lock(); guard !cancelled else { lock.unlock(); throw CancellationError() }; process = child; lock.unlock()
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); lock.lock(); process = nil; lock.unlock() }
        try child.run(); try output.fileHandleForWriting.close()
        let deadline = DispatchWorkItem { [self] in
            lock.lock(); timedOut = process?.isRunning == true; lock.unlock(); cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        lock.lock(); let stop = cancelled; lock.unlock(); if stop { cancel() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 8_192), !chunk.isEmpty {
            guard data.count + chunk.count <= 65_536 else { cancel(); child.waitUntilExit(); throw CorePluginError.invalid("Plugin output exceeded 64 KB and was stopped.") }
            data.append(chunk)
        }
        child.waitUntilExit()
        lock.lock(); let cancelled = self.cancelled; let timeout = timedOut; lock.unlock()
        if timeout { throw CorePluginError.invalid("Plugin command exceeded the five-second limit and was stopped.") }
        if cancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            // Keep launcher/dyld errors visible for supported-runtime failures;
            // output remains bounded and is never applied on failure.
            let raw = String(decoding: data.prefix(4_096), as: UTF8.self)
            let diagnostic = String(raw.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
            }).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PlusPluginProcessFailure(status: child.terminationStatus,
                terminatedBySignal: child.terminationReason == .uncaughtSignal, processID: child.processIdentifier, diagnostic: diagnostic)
        }
        return data
    }
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        guard let child, child.isRunning else { return }
        let pid = child.processIdentifier
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            lock.lock(); let running = process?.processIdentifier == pid && process?.isRunning == true; lock.unlock()
            if running { kill(pid, SIGKILL) }
        }
    }
}
