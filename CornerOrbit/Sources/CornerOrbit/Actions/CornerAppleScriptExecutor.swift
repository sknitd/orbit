import Foundation
import Darwin

protocol CornerScriptExecuting: Sendable {
    func execute(_ request: CornerAppleScriptRequest) async throws
}

struct CornerAppleScriptExecutor: CornerScriptExecuting {
    let timeout: TimeInterval
    let outputLimit: Int
    init(timeout: TimeInterval = 30, outputLimit: Int = 32_768) {
        self.timeout = min(60, max(0.05, timeout.isFinite ? timeout : 30))
        self.outputLimit = min(65_536, max(1_024, outputLimit))
    }
    func execute(_ request: CornerAppleScriptRequest) async throws {
        let process = CornerScriptProcess(timeout: timeout, outputLimit: outputLimit)
        try await process.run(request.source)
        try Task.checkCancellation()
    }
}

private final class CornerScriptProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    init(timeout: TimeInterval, outputLimit: Int) { self.timeout = timeout; self.outputLimit = outputLimit }
    func run(_ source: String) async throws {
        let work = Task.detached(priority: .userInitiated) { try self.execute(source) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { self.cancel(); work.cancel() }
    }
    private func execute(_ source: String) throws {
        try Task.checkCancellation()
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        child.arguments = ["-e", source]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe
        lock.lock(); guard !cancelled else { lock.unlock(); throw CancellationError() }; process = child; lock.unlock()
        defer {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            lock.lock(); process = nil; lock.unlock()
        }
        try child.run(); try pipe.fileHandleForWriting.close()
        let deadline = DispatchWorkItem { [self] in
            lock.lock(); let running = process?.isRunning == true; if running { self.timedOut = true }; lock.unlock()
            if running { cancel() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        lock.lock(); let mustStop = cancelled; lock.unlock(); if mustStop { cancel() }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 8_192), !chunk.isEmpty {
            guard data.count + chunk.count <= outputLimit else {
                cancel(); child.waitUntilExit(); throw CornerActionExecutionError.scriptOutputLimit
            }
            data.append(chunk)
        }
        child.waitUntilExit()
        lock.lock(); let wasCancelled = self.cancelled, exceededTimeout = self.timedOut; lock.unlock()
        if exceededTimeout { throw CornerActionExecutionError.scriptTimedOut(timeout) }
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let diagnostic = String(decoding: data.prefix(4_096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CornerActionExecutionError.scriptFailed(status: child.terminationStatus, diagnostic: diagnostic)
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        guard let child, child.isRunning else { return }
        let pid = child.processIdentifier; Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.lock(); let running = process?.processIdentifier == pid && process?.isRunning == true; lock.unlock()
            if running { Darwin.kill(pid, SIGKILL) }
        }
    }
}
