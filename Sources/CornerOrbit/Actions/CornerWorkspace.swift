import Foundation
import AppKit

@MainActor
protocol CornerWorkspaceAccessing {
    func applicationURL(bundleID: String) -> URL?
    func openApplication(at url: URL) async throws
    func openWebsite(_ url: URL, in application: URL) async throws
    func openDirectory(_ url: URL) async throws
    func openFile(_ url: URL) async throws
    func openFile(_ url: URL, in application: URL) async throws
}

extension CornerWorkspaceAccessing {
    // Older injected workspaces fail visibly instead of performing a native side effect.
    func openFile(_ url: URL) async throws { throw CornerActionExecutionError.launchFailed("This workspace cannot open files.") }
    func openFile(_ url: URL, in application: URL) async throws { throw CornerActionExecutionError.launchFailed("This workspace cannot open a file in the selected application.") }
}

/// One callback, timeout, or cancellation resumes each request once.
private final class CornerWorkspaceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?
    private var completed = false
    private var deadline: DispatchWorkItem?
    func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(CornerActionExecutionError.launchTimedOut)) }
        self.deadline = deadline
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
        return true
    }
    func finish(_ result: Result<Void, any Error>) {
        lock.lock(); guard !completed else { lock.unlock(); return }
        completed = true; self.result = result
        let continuation = continuation; self.continuation = nil
        let deadline = deadline; self.deadline = nil
        lock.unlock()
        deadline?.cancel(); continuation?.resume(with: result)
    }
}

@MainActor
final class CornerNativeWorkspace: CornerWorkspaceAccessing {
    func applicationURL(bundleID: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        // Hidden system helpers may not be registered with Launch Services.
        let fallback: String?
        switch bundleID {
        case "com.apple.screencaptureui": fallback = "/System/Applications/Utilities/Screenshot.app"
        case "com.apple.ScreenSaver.Engine": fallback = "/System/Library/CoreServices/ScreenSaverEngine.app"
        default: fallback = nil
        }
        guard let fallback else { return nil }
        let url = URL(fileURLWithPath: fallback, isDirectory: true)
        return Bundle(url: url)?.bundleIdentifier == bundleID ? url : nil
    }
    func openApplication(at url: URL) async throws {
        try Task.checkCancellation()
        let reply = CornerWorkspaceReply()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard reply.install(continuation) else { return }
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                    if let error { reply.finish(.failure(CornerActionExecutionError.launchFailed(error.localizedDescription))) }
                    else if application != nil { reply.finish(.success(())) }
                    else { reply.finish(.failure(CornerActionExecutionError.launchFailed("macOS returned no running application."))) }
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
    func openWebsite(_ url: URL, in application: URL) async throws {
        try Task.checkCancellation()
        let reply = CornerWorkspaceReply()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard reply.install(continuation) else { return }
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { application, error in
                    if let error { reply.finish(.failure(CornerActionExecutionError.launchFailed(error.localizedDescription))) }
                    else if application != nil { reply.finish(.success(())) }
                    else { reply.finish(.failure(CornerActionExecutionError.launchFailed("macOS returned no browser application."))) }
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
    func openFile(_ url: URL, in application: URL) async throws {
        try requireExistingLocalFile(url)
        try await openWebsite(url, in: application)
    }
    func openFile(_ url: URL) async throws {
        try Task.checkCancellation()
        try requireExistingLocalFile(url)
        guard NSWorkspace.shared.open(url) else { throw CornerActionExecutionError.launchFailed("macOS rejected the file or folder request.") }
    }
    private func requireExistingLocalFile(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw CornerActionExecutionError.launchFailed("The selected local file or folder is unavailable.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard values.isRegularFile == true || values.isDirectory == true else {
            throw CornerActionExecutionError.launchFailed("The selected target is not a regular local file or folder.")
        }
    }
    func openDirectory(_ url: URL) async throws {
        try Task.checkCancellation()
        guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CornerActionExecutionError.launchFailed("The folder is unavailable.")
        }
        guard NSWorkspace.shared.open(url) else { throw CornerActionExecutionError.launchFailed("macOS rejected the folder request.") }
    }
}
