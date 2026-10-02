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
        triggerOption = defaults.bool(forKey: "triggerOption")
        quality = defaults.object(forKey: "quality") as? Double ?? 0.82
        outputDownloads = defaults.bool(forKey: "outputDownloads")
        retainHistory = defaults.bool(forKey: "retainHistory")
        sound = defaults.bool(forKey: "sound")
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
    var recent: [RecentResult] = []
    var monitoringStatus = "Input Monitoring has not been checked."
    var onResults: (() -> Void)?
    private var currentTask: Task<Void, Never>?
    private var activeID: UUID?
    private var undoMetadata: [URL: (size: Int, modified: Date)] = [:]

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
                let items = try await Task.detached { try FileInspector.inspect(urls) }.value
                guard ActionResolver.actions(for: items).contains(where: { $0.id == action.id }) else {
                    throw OrbitError.invalidInput("These files no longer support the selected action.")
                }
                try Task.checkCancellation()
                let context = ActionContext(outputDirectory: destination, quality: quality) { [weak self] value, label in
                    Task { @MainActor in
                        guard self?.activeID == identifier else { return }
                        self?.progress = value; self?.progressLabel = label
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
                self.undoMetadata = [:]
                for output in result.outputs {
                    let values = try output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if let date = values.contentModificationDate { self.undoMetadata[output] = (values.fileSize ?? 0, date) }
                }
                let entry = RecentResult(title: action.title, result: result)
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

    func undoLast() {
        guard !busy, let entry = recent.first else { return }
        do {
            for output in entry.result.outputs {
                let values = try output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let recorded = undoMetadata[output], recorded.size == values.fileSize,
                      recorded.modified == values.contentModificationDate else {
                    throw OrbitError.failed("A result changed after creation. Reveal it to manage it safely.")
                }
            }
            for output in entry.result.outputs { try FileManager.default.trashItem(at: output, resultingItemURL: nil) }
            recent.removeFirst(); undoMetadata = [:]
        } catch { errorMessage = error.localizedDescription; onResults?() }
    }

    func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}
