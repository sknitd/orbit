import Foundation
import Darwin
import NotchCore

/// Public Codex app-server protocol. Runs on a detached task; pipe reads never block the main actor.
enum OnlineCodexQuotaReader {
    static func read(executable: URL) async throws -> OnlineCodexQuota {
        let worker = Task.detached(priority: .userInitiated) { try run(executable: executable) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func run(executable: URL) throws -> OnlineCodexQuota {
        try Task.checkCancellation()
        let resolved = executable.standardizedFileURL.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw OnlineServiceError.message("Choose a trusted, executable Codex CLI installed on this Mac.")
        }
        let process = Process(); process.executableURL = resolved; process.arguments = ["app-server"]
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-Codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = [executable.deletingLastPathComponent().path, resolved.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", inheritedPath].joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // An old or failed CLI can close stdin before initialize is sent.
        // Receive EPIPE as a thrown write error instead of terminating the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw OnlineServiceError.message("Could not protect the Codex protocol channel.")
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw OnlineServiceError.message("Could not open the Codex protocol channel.")
        }
        defer {
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 where process.isRunning { usleep(10_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        do { try process.run() } catch { throw OnlineServiceError.message("The selected CLI could not start. Choose an installed Codex executable.") }
        // Close the parent-side output writer so an exited server produces EOF.
        try output.fileHandleForWriting.close()
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw OnlineServiceError.message("Codex closed its protocol channel.") }
        }
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "notchorbitplus", "title": "NotchOrbitPlus", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false, "requestAttestation": false, "explicitGatewayOauth": true]]])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(14))
        var buffer = Data(), totalBytes = 0
        var initialized = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while clock.now < deadline {
            try Task.checkCancellation()
            let count = chunk.withUnsafeMutableBytes { bytes in Darwin.read(descriptor, bytes.baseAddress, bytes.count) }
            if count > 0 {
                totalBytes += count
                guard totalBytes <= 65_536 else { throw OnlineServiceError.message("Codex protocol output exceeded its 64 KB safety limit.") }
                buffer.append(contentsOf: chunk.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw OnlineServiceError.message("The CLI returned an unsupported protocol message. Update Codex and retry.")
                    }
                    if message["method"] != nil && message["id"] != nil {
                        throw OnlineServiceError.message("Codex requested an interactive operation. This tool accepts quota responses only; use Terminal to sign in or configure the CLI.")
                    }
                    let id = (message["id"] as? NSNumber)?.intValue
                    if id == 1 && !initialized {
                        guard message["error"] == nil, message["result"] != nil else {
                            throw OnlineServiceError.message("Codex rejected initialization. Update your CLI; no sign-in or account changes were requested.")
                        }
                        initialized = true
                        try send(["method": "initialized"])
                        try send(["id": 2, "method": "account/rateLimits/read"])
                    } else if id == 2 && initialized {
                        guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                            throw OnlineServiceError.message("Codex could not read subscription limits. Sign in in Terminal, check your plan and update the CLI.")
                        }
                        let safe = try JSONSerialization.data(withJSONObject: result)
                        return try OnlineCodexQuota.decodeResult(safe)
                    }
                    // Notifications are deliberately discarded without logging or account/token extraction.
                }
            } else if count == 0 {
                throw OnlineServiceError.message("Codex exited before returning quota data. Check the selected executable and CLI version.")
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw OnlineServiceError.message("Could not read the Codex protocol response.")
            }
            usleep(20_000)
        }
        throw OnlineServiceError.message("Codex quota read timed out after 14 seconds. The app stopped its own CLI process.")
    }
}
