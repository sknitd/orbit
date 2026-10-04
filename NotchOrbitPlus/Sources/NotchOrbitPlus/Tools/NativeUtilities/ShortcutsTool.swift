import SwiftUI
import AppKit
import Darwin
import NotchCore

private struct OrbitShortcutProcessResult: Sendable { let status: Int32; let output: String }

/// Owns one subprocess. Cancellation is checked both before and after launch;
/// stdout/stderr are drained together to prevent pipe backpressure deadlocks.
private final class OrbitShortcutProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(_ arguments: [String]) async throws -> OrbitShortcutProcessResult {
        let work = Task.detached(priority: .userInitiated) { try self.execute(arguments) }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { self.cancel(); work.cancel() }
    }

    private func execute(_ arguments: [String]) throws -> OrbitShortcutProcessResult {
        try Task.checkCancellation()
        let command = Process(); let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        command.arguments = arguments
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = pipe; command.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = command
        lock.unlock()
        defer {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            lock.lock(); process = nil; lock.unlock()
        }
        try command.run()
        try pipe.fileHandleForWriting.close()
        lock.lock(); let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { cancel() }
        var output = Data(); var truncated = false
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            let remaining = max(0, 1_048_576 - output.count)
            output.append(chunk.prefix(remaining))
            if chunk.count > remaining { truncated = true }
        }
        command.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        let text = String(decoding: output, as: UTF8.self) + (truncated ? "\n[Output truncated after 1 MB]" : "")
        return OrbitShortcutProcessResult(status: command.terminationStatus, output: text)
    }

    func cancel() {
        lock.lock(); cancelled = true
        let pid = process?.isRunning == true ? process?.processIdentifier : nil
        lock.unlock()
        guard let pid else { return }
        kill(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock(); let stillRunning = process?.processIdentifier == pid && process?.isRunning == true; lock.unlock()
            if stillRunning { kill(pid, SIGKILL) }
        }
    }
}

@MainActor
private final class OrbitShortcutsModel: ObservableObject {
    @Published var choices: [OrbitShortcutChoice] = []
    @Published var selectedID = ""
    @Published var busy = false
    @Published var message = "Load the shortcuts installed in Apple's Shortcuts app."
    private var task: Task<Void, Never>?
    private var process: OrbitShortcutProcess?
    private var generation = UUID()

    func load() { execute(["list", "--show-identifiers"], listing: true) }
    func runSelected() {
        guard choices.contains(where: { $0.id == selectedID }) else { return }
        // A parsed UUID is used as the argument, so a shortcut's display name
        // can never inject an option or command into CLI execution.
        execute(["run", selectedID], listing: false)
    }
    private func execute(_ arguments: [String], listing: Bool) {
        guard !busy else { return }
        let operation = OrbitShortcutProcess(); process = operation
        let id = UUID(); generation = id; busy = true
        message = listing ? "Reading shortcuts…" : "Running selected shortcut…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.busy = false; self.task = nil; self.process = nil } }
            do {
                let result = try await operation.run(arguments)
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard result.status == 0 else {
                    self.message = result.output.isEmpty ? "Shortcuts exited with status \(result.status)." : result.output
                    return
                }
                if listing {
                    self.choices = try OrbitShortcutListing.parse(result.output)
                    if !self.choices.contains(where: { $0.id == self.selectedID }) { self.selectedID = self.choices.first?.id ?? "" }
                    self.message = self.choices.isEmpty ? "No shortcuts found. Create one in Shortcuts, then refresh." : "\(self.choices.count) shortcuts available."
                } else { self.message = result.output.isEmpty ? "Shortcut finished successfully." : result.output }
            } catch is CancellationError {
                if self.generation == id { self.message = "Shortcut command cancelled." }
            } catch { if self.generation == id { self.message = error.localizedDescription } }
        }
    }
    func cancel() { process?.cancel(); task?.cancel() }
}

@MainActor
struct ShortcutsToolView: View {
    @StateObject private var model = OrbitShortcutsModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts").font(.headline)
            HStack {
                Button("Load / Refresh", action: model.load).disabled(model.busy)
                Button("Open Shortcuts") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") { NSWorkspace.shared.open(url) }
                }
            }
            if !model.choices.isEmpty {
                Picker("Shortcut", selection: $model.selectedID) {
                    ForEach(model.choices) { Text($0.name).tag($0.id) }
                }.disabled(model.busy)
                Button("Run selected shortcut", action: model.runSelected).disabled(model.busy || model.selectedID.isEmpty)
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel) } }
            Text(model.message).font(.caption).textSelection(.enabled)
            Text("Runs the selected shortcut and its actions. Actions may request input or permissions.")
                .font(.caption).foregroundStyle(.secondary)
        }.onDisappear { model.cancel() }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: model.cancel).frame(width: 0, height: 0))
    }
}
