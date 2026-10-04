import Foundation
import AppKit

@MainActor
protocol CornerWorkspaceAccessing {
    func applicationURL(bundleID: String) -> URL?
    func openApplication(at url: URL) async throws
    func openWebsite(_ url: URL, in application: URL) async throws
    func openDirectory(_ url: URL) async throws
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
    func applicationURL(bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
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
    func openDirectory(_ url: URL) async throws {
        try Task.checkCancellation()
        guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CornerActionExecutionError.launchFailed("The folder is unavailable.")
        }
        guard NSWorkspace.shared.open(url) else { throw CornerActionExecutionError.launchFailed("macOS rejected the folder request.") }
    }
}
