import AppKit
import Observation
import OrbitCore
import ServiceManagement

@MainActor @Observable
final class Preferences {
    var triggerOption: Bool { didSet { defaults.set(triggerOption, forKey: "triggerOption") } }
    var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
    var outputDownloads: Bool { didSet { defaults.set(outputDownloads, forKey: "outputDownloads") } }
    var retainHistory: Bool { didSet { defaults.set(retainHistory, forKey: "retainHistory") } }
    var sound: Bool { didSet { defaults.set(sound, forKey: "sound") } }
    var paused = false
    private let defaults = UserDefaults.standard
    init() {
        let settings = UserDefaults.standard
        triggerOption = settings.bool(forKey: "triggerOption")
        let savedQuality = settings.object(forKey: "quality") as? Double ?? 0.82
        quality = savedQuality.isFinite ? min(1, max(0.4, savedQuality)) : 0.82
        outputDownloads = settings.bool(forKey: "outputDownloads")
        retainHistory = settings.bool(forKey: "retainHistory")
        sound = settings.bool(forKey: "sound")
    }
}

struct RecentResult: Identifiable {
    let id = UUID()
    let title: String
    let result: ActionResult
    let date = Date()
}

@MainActor @Observable
final class AppModel {
    let preferences = Preferences()
    var progress = 0.0
    var progressLabel = ""
    var busy = false
    var errorMessage: String?
    private var recentStorage: [RecentResult] = []
    var recent: [RecentResult] {
        get {
            if preferences.retainHistory {
                let now = Date()
                return recentStorage.filter { now.timeIntervalSince($0.date) < 86_400 }
            }
            return Array(recentStorage.prefix(1))
        }
        set { recentStorage = newValue }
    }
    var monitoringStatus = "Input Monitoring has not been checked."
    var onResults: (@MainActor () -> Void)?
    private var currentTask: Task<Void, Never>?
    private var activeID: UUID?
    private struct UndoMetadata {
        let size: Int
        let modified: Date
        let identifier: NSObject
    }
    private var undoMetadata: [URL: UndoMetadata] = [:]
    private var undoEntryID: UUID?
    private var undoUnavailableReason: String?

    var canUndo: Bool {
        guard !busy, let entry = recent.first, entry.id == undoEntryID,
              !entry.result.outputs.isEmpty else { return false }
        return entry.result.outputs.allSatisfy { undoMetadata[$0] != nil }
    }

    var undoHelp: String {
        if busy { return "Wait for the current operation to finish before using Undo." }
        if let reason = undoUnavailableReason { return reason }
        if recent.isEmpty { return "There is no generated result to undo." }
        // These checks detect ordinary edits and file replacement. They are not
        // a content hash and cannot detect edits that preserve all three values.
        return "Undo moves generated files to Trash after checking their identity, size, and modification date. Edits that preserve those values cannot be detected."
    }

    func run(_ action: ActionDescriptor, urls: [URL]) {
        guard !busy else {
            errorMessage = "Another operation is running. Cancel it or wait for it to finish."
            onResults?(); return
        }
        busy = true; progress = 0; progressLabel = "Inspecting files…"; errorMessage = nil
        let identifier = UUID(); activeID = identifier
        let quality = preferences.quality
        let destination = preferences.outputDownloads ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first : nil
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.currentTask = nil; self.activeID = nil }
            do {
                let inspection = Task.detached(priority: .userInitiated) { try FileInspector.inspect(urls) }
                let items = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
                try Task.checkCancellation()
                guard ActionResolver.actions(for: items).contains(where: { $0.id == action.id }) else {
                    throw OrbitError.invalidInput("These files no longer support the selected action.")
                }
                try Task.checkCancellation()
                let context = ActionContext(outputDirectory: destination, quality: quality) { [weak self] value, label in
                    Task { @MainActor in
                        guard self?.activeID == identifier, value.isFinite else { return }
                        self?.progress = min(1, max(0, value)); self?.progressLabel = label
                    }
                }
                let engine: any ActionEngine
                switch action.id {
                case .jpeg, .png, .heic, .webp, .compressImage, .resize1600, .removeMetadata, .removeGPS:
                    engine = ImageEngine()
                case .imagesToPDF, .mergePDF, .splitPDF, .pdfToPNG, .ocr:
                    engine = PDFEngine()
                case .videoMP4, .compressVideo, .extractAudio, .audioM4A:
                    engine = NativeMediaEngine()
                case .zip, .unzip: engine = ArchiveEngine()
                case .checksum, .duplicate, .formatJSON, .minifyJSON: engine = FileEngine()
                }
                self.progressLabel = action.title
                let result = try await engine.perform(action.id, items: items, context: context)
                guard !result.outputs.isEmpty else { throw OrbitError.failed("No output was produced.") }
                // The engine owns cancellation and cleanup until it returns.
                // Preserve completed outputs even if Undo metadata is unavailable.
                let entry = RecentResult(title: action.title, result: result)
                self.rememberUndo(for: entry)
                if self.preferences.retainHistory {
                    self.recent = ([entry] + self.recent).filter { Date().timeIntervalSince($0.date) < 86_400 }.prefix(20).map { $0 }
                } else { self.recent = [entry] }
                self.progress = 1; self.progressLabel = "Completed"
                if self.preferences.sound { NSSound(named: "Glass")?.play() }
                self.onResults?()
            } catch is CancellationError {
                self.errorMessage = "Operation cancelled. Originals are unchanged."; self.onResults?()
            } catch {
                self.errorMessage = error.localizedDescription; self.onResults?()
            }
        }
        onResults?()
    }

    func cancel() { currentTask?.cancel() }

    private func rememberUndo(for entry: RecentResult) {
        undoMetadata = [:]; undoEntryID = entry.id; undoUnavailableReason = nil
        for output in entry.result.outputs {
            guard let values = try? output.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
            ]) else {
                undoUnavailableReason = "Undo cannot verify this result. Reveal it to manage it safely."
                continue
            }
            if values.isDirectory == true {
                undoUnavailableReason = "Undo is unavailable for extracted folders because files inside may have changed. Reveal the folder to move it to Trash yourself."
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, let date = values.contentModificationDate,
                  let identifier = values.fileResourceIdentifier as? NSObject else {
                undoUnavailableReason = "Undo cannot verify this result. Reveal it to manage it safely."
                continue
            }
            undoMetadata[output] = UndoMetadata(size: size, modified: date, identifier: identifier)
        }
    }

    func undoLast() {
        guard let entry = recent.first else { return }
        guard canUndo else { errorMessage = undoHelp; onResults?(); return }
        var trashedCount = 0
        do {
            for output in entry.result.outputs {
                let values = try output.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey, .fileResourceIdentifierKey
                ])
                guard let recorded = undoMetadata[output], recorded.size == values.fileSize,
                      recorded.modified == values.contentModificationDate,
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let identifier = values.fileResourceIdentifier as? NSObject,
                      recorded.identifier.isEqual(identifier) else {
                    throw OrbitError.failed("A result changed or was replaced after creation. Reveal it to manage it safely.")
                }
            }
            for output in entry.result.outputs {
                try FileManager.default.trashItem(at: output, resultingItemURL: nil)
                trashedCount += 1
            }
            recent.removeFirst(); undoMetadata = [:]; undoEntryID = nil
            undoUnavailableReason = recent.isEmpty ? nil : "Only the latest operation can be undone. Reveal older results to manage them."
            errorMessage = nil
        } catch {
            undoMetadata = [:]; undoEntryID = nil
            undoUnavailableReason = "Undo could not safely finish. Reveal the remaining results to manage them."
            if trashedCount > 0 {
                errorMessage = "Undo moved \(trashedCount) of \(entry.result.outputs.count) outputs to Trash before it stopped. Remaining outputs are still in their saved locations. \(error.localizedDescription)"
            } else { errorMessage = error.localizedDescription }
        }
        onResults?()
    }

    func clearRecent() {
        recent = []; undoMetadata = [:]; undoEntryID = nil; undoUnavailableReason = nil
    }

    func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}
