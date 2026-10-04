import Foundation
import Darwin
import NotchCore

struct PlusPluginPackage: Sendable {
    let manifest: CorePluginManifest
    let scripts: [String: Data]
}
enum PlusPluginFolderIO {
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
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
    static var available: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
    static func profile(folder: URL, writable: Bool, readFolders: [URL]) throws -> String {
        guard folder.isFileURL, readFolders.count <= 4, readFolders.allSatisfy(\.isFileURL) else { throw CorePluginError.invalid("Invalid plugin folder grants.") }
        func literal(_ path: String) throws -> String {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CorePluginError.invalid("Folder path contains unsupported control characters.") }
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let root = try literal(folder.resolvingSymlinksInPath().path)
        var profile = """
        (version 1)
        (deny default)
        (allow process-exec (literal "/bin/sh"))
        (allow sysctl-read)
        (allow file-read* (subpath "/System/Library") (subpath "/usr/lib") (literal "/bin/sh") (subpath \(root)))
        (allow file-map-executable (subpath "/System/Library") (subpath "/usr/lib") (literal "/bin/sh"))
        """
        for folder in readFolders { profile += "\n(allow file-read* (subpath \(try literal(folder.resolvingSymlinksInPath().path))))" }
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
        let profile = try PlusPluginSandbox.profile(folder: folder, writable: grants.contains(.ownFolderWrite), readFolders: readFolders)
        let work = Task.detached(priority: .userInitiated) { try self.execute(folder: folder, command: command, profile: profile, clipboard: clipboard, readFolders: readFolders) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { self.cancel(); work.cancel() }
    }
    private func execute(folder: URL, command: CorePluginCommand, profile: String, clipboard: String?, readFolders: [URL]) throws -> Data {
        try Task.checkCancellation()
        let child = Process(); let output = Pipe()
        child.executableURL = PlusPluginSandbox.executable
        child.arguments = ["-p", profile, "/bin/sh", folder.appendingPathComponent(command.script).path]
        child.currentDirectoryURL = folder
        var environment = ["PATH": "/nonexistent", "LC_ALL": "C", "ORBIT_PLUGIN_API": "1"]
        if let clipboard { environment["ORBIT_CLIPBOARD"] = clipboard }
        for (index, folder) in readFolders.enumerated() { environment["ORBIT_READ_FOLDER_\(index)"] = folder.path }
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
        guard child.terminationStatus == 0 else { throw CorePluginError.invalid("Plugin command or sandbox exited with status \(child.terminationStatus). No output was applied.") }
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
