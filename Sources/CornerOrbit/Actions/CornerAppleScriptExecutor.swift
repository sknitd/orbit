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
        let process = CornerCommandProcess(timeout: timeout, outputLimit: outputLimit)
        _ = try await process.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", request.source])
        try Task.checkCancellation()
    }
}

final class CornerCommandProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var process: Process?
    private var cancelled = false
    init(timeout: TimeInterval, outputLimit: Int) {
        self.timeout = min(60, max(0.05, timeout.isFinite ? timeout : 30))
        self.outputLimit = min(65_536, max(1_024, outputLimit))
    }
    func run(executable: URL, arguments: [String]) async throws -> Data {
        let work = Task.detached(priority: .userInitiated) { try self.execute(executable: executable, arguments: arguments) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { self.cancel(); work.cancel() }
    }
    private func execute(executable: URL, arguments: [String]) throws -> Data {
        try Task.checkCancellation()
        let child = Process(), pipe = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe
        lock.lock(); guard !cancelled else { lock.unlock(); throw CancellationError() }; process = child; lock.unlock()
        defer {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            lock.lock(); process = nil; lock.unlock()
        }
        try child.run()
        defer { if child.isRunning { cancel() } }
        try pipe.fileHandleForWriting.close()
        // Readers never wait for EOF from a Shortcut's descendants. Only the
        // launched child is tracked; available output is drained after its exit.
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO); cancel(); throw error
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        var reachedEOF = false
        while true {
            try Task.checkCancellation()
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { throw CancellationError() }
            let running = child.isRunning
            if reachedEOF && !running { break }
            if DispatchTime.now().uptimeNanoseconds >= deadline { cancel(); throw CornerActionExecutionError.scriptTimedOut(timeout) }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = reachedEOF ? Darwin.poll(nil, 0, 50) : Darwin.poll(&item, 1, running ? 50 : 0)
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if reachedEOF { continue }
            if ready == 0 { if !running { break }; continue }
            let amount = buffer.withUnsafeMutableBytes { bytes in Darwin.read(descriptor, bytes.baseAddress, bytes.count) }
            if amount > 0 {
                guard amount <= outputLimit - data.count else { cancel(); throw CornerActionExecutionError.scriptOutputLimit }
                data.append(contentsOf: buffer.prefix(amount))
            } else if amount == 0 {
                reachedEOF = true
            } else {
                let failure = errno
                if failure == EINTR { continue }
                if failure == EAGAIN || failure == EWOULDBLOCK { if !child.isRunning { break }; continue }
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
        }
        try Task.checkCancellation()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let diagnostic = String(decoding: data.prefix(4_096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CornerActionExecutionError.scriptFailed(status: child.terminationStatus, diagnostic: diagnostic)
        }
        try Task.checkCancellation()
        return data
    }
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        guard let child, child.isRunning else { return }
        let termination = CornerCommandTermination(child)
        Darwin.kill(child.processIdentifier, SIGTERM)
        // This lease survives output-pipe cleanup so a resistant tracked child
        // still receives SIGKILL after the caller has returned cancellation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { termination.killIfRunning() }
    }
}

private final class CornerCommandTermination: @unchecked Sendable {
    private let child: Process
    private let pid: Int32
    init(_ child: Process) { self.child = child; pid = child.processIdentifier }
    func killIfRunning() {
        if child.processIdentifier == pid && child.isRunning { Darwin.kill(pid, SIGKILL) }
    }
}
