import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import OrbitCore
import NotchCore

struct CaptureDisplayChoice: Identifiable { let id: UInt32; let name: String }
struct CaptureWindowChoice: Identifiable { let id: UInt32; let name: String }

@MainActor
final class ScreenshotShelfStore: ObservableObject {
    static let shared = ScreenshotShelfStore()
    @Published var selection: CaptureSelectionKind = .display
    @Published var displayID: UInt32?
    @Published var windowID: UInt32?
    @Published var duration = 10.0
    @Published var showsCursor = false
    @Published private(set) var displays: [CaptureDisplayChoice] = []
    @Published private(set) var windows: [CaptureWindowChoice] = []
    @Published private(set) var history: [CaptureShelfRecord] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Capture starts only when you choose Start."
    @Published private(set) var error: String?
    @Published private(set) var progress = 0.0
    private let persistState: Bool
    private let suppliedShelf: FileShelfToolStore?
    private let permissionCheck: @MainActor () -> Bool
    private let permissionRequest: @MainActor () -> Bool
    private let selector = CaptureAreaSelector()
    private var task: Task<Void, Never>?
    private var intentTask: Task<FileShelfItem, Error>?
    private var deadline: Task<Void, Never>?
    private var generation: UUID?
    private var active: CaptureSession?
    private var visible = false
    private var preparingRecording = false

    init(shelf: FileShelfToolStore? = nil, persistState: Bool = true,
         permissionCheck: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         permissionRequest: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() }) {
        suppliedShelf = shelf; self.persistState = persistState
        self.permissionCheck = permissionCheck; self.permissionRequest = permissionRequest
        refreshDisplayChoices()
        if persistState {
            do { history = try LocalToolStorage.load(CaptureShelfArchive.self, file: "capture-shelf.json", fallback: .init()).validated().records }
            catch { self.error = "Could not load capture history. Its original data was retained: \(error.localizedDescription)" }
        }
    }
    func setVisible(_ value: Bool) {
        // Selection/sampling overlays do not count as hidden in CaptureToolVisibility.
        // An actual hide/tab switch cancels every active capture, including a PNG.
        // An explicit Intent may start while already hidden; this is transition-based.
        if visible && !value && (preparingRecording || isRecording || isWorking) { cancel() }
        visible = value
        if value { refreshDisplayChoices() }
    }
    func shutdown() { cancel(); visible = false }
    private func refreshDisplayChoices() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CaptureDisplayChoice(id: number.uint32Value, name: screen.localizedName)
        }
        if !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id }
    }
    private func begin() throws -> UUID {
        guard !isWorking, !isRecording else { throw ScreenCaptureFailure.encoding("A capture is already active.") }
        let token = UUID(); generation = token; isWorking = true; progress = 0; error = nil
        return token
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func permission() throws {
        guard permissionCheck() || permissionRequest() else { throw ScreenCaptureFailure.permission }
    }
    func startScreenshot() {
        let token: UUID
        do { token = try begin() } catch { self.error = error.localizedDescription; return }
        let kind = selection
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            defer { if store.generation == token { store.isWorking = false; store.task = nil } }
            do { _ = try await store.takeScreenshot(kind: kind, token: token) }
            catch is CancellationError { if store.generation == token { store.status = "Capture cancelled; partial files were removed." } }
            catch { if store.generation == token { store.error = error.localizedDescription; store.status = "Capture did not publish a file." } }
        }
    }
    /// App Intents are explicit starts, and await the actual PNG plus durable shelf publication.
    func captureFullScreenForIntent() async throws -> FileShelfItem {
        try Task.checkCancellation()
        let token = try begin()
        let child = Task { @MainActor [self] in
            try await takeScreenshot(kind: .display, token: token)
        }
        intentTask = child
        defer { if generation == token { isWorking = false; intentTask = nil } }
        do {
            let item = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
            try check(token)
            return item
        } catch {
            if generation == token {
                if error is CancellationError { status = "Capture cancelled; no incomplete output was published." }
                else { self.error = error.localizedDescription; status = "Capture did not publish a file." }
            }
            throw error
        }
    }
    private func takeScreenshot(kind: CaptureSelectionKind, token: UUID) async throws -> FileShelfItem {
        try check(token); status = "Preparing screenshot…"; try permission(); try check(token)
        let plan = try await makePlan(kind: kind, recording: false, token: token)
        try check(token); status = "Capturing the selected source…"
        let image = try await SCScreenshotManager.captureImage(contentFilter: plan.filter, configuration: plan.configuration)
        try check(token)
        let directory = try ScreenCaptureFiles.stagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Screenshot-\(UUID().uuidString.prefix(8)).png")
        let owned = CaptureOwnedImage(image)
        let child = Task.detached(priority: .userInitiated) { try ScreenCaptureFiles.writePNG(owned.value, at: source) }
        try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
        try check(token)
        return try await publishCapture(source, token: token, kind: kind, width: image.width,
            height: image.height, status: "Screenshot saved to File Shelf.")
    }

    func startRecording() {
        let token: UUID
        do { _ = try CaptureGeometry.duration(duration); token = try begin() }
        catch { self.error = error.localizedDescription; return }
        preparingRecording = true
        let kind = selection; let limit = duration
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            var pending: CaptureSession?
            do {
                try store.check(token)
                store.status = "Preparing recording…"; try store.permission(); try store.check(token)
                let plan = try await store.makePlan(kind: kind, recording: true, token: token)
                try store.check(token)
                let directory = try ScreenCaptureFiles.stagingDirectory()
                let url = directory.appendingPathComponent("Recording-\(UUID().uuidString.prefix(8)).mov")
                let writer: CaptureMovieWriter
                do {
                    writer = try CaptureMovieWriter(url: url, width: plan.configuration.width,
                        height: plan.configuration.height) { [store] message in
                            Task { @MainActor [store] in
                                guard store.generation == token else { return }
                                store.error = message; store.cancel()
                            }
                        }
                } catch { try? FileManager.default.removeItem(at: directory); throw error }
                let stream = SCStream(filter: plan.filter, configuration: plan.configuration, delegate: writer)
                let session = CaptureSession(stream: stream, writer: writer, directory: directory,
                                             kind: kind, startedAt: Date(), token: token)
                pending = session
                try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
                try await stream.startCapture(); try store.check(token)
                store.active = CaptureSession(stream: stream, writer: writer, directory: directory,
                    kind: kind, startedAt: Date(), token: token)
                pending = nil
                store.preparingRecording = false
                store.isRecording = true; store.isWorking = false; store.task = nil
                store.status = "Recording up to \(Int(limit)) seconds. Stop and Save ends it early."
                store.deadline = Task { @MainActor [weak store] in
                    do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                    guard let store, store.generation == token else { return }
                    store.stopRecording(discard: false)
                }
            } catch {
                if let pending {
                    try? await pending.stream.stopCapture(); await pending.writer.cancel()
                    try? FileManager.default.removeItem(at: pending.directory)
                }
                if store.generation == token {
                    store.preparingRecording = false; store.isWorking = false; store.task = nil
                    if error is CancellationError { store.status = "Recording cancelled; incomplete output was discarded." }
                    else { store.error = error.localizedDescription; store.status = "Recording could not start." }
                }
            }
        }
    }
    func stopAndSave() { stopRecording(discard: false) }
    private func stopRecording(discard: Bool) {
        guard let session = active else { return }
        active = nil; deadline?.cancel(); deadline = nil
        isRecording = false; isWorking = true
        let token = session.token
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            defer {
                try? FileManager.default.removeItem(at: session.directory)
                if store.generation == token { store.isWorking = false; store.task = nil }
            }
            do {
                try await session.stream.stopCapture()
                if discard {
                    await session.writer.cancel()
                    if store.generation == token { store.status = "Recording discarded; no file was added." }
                    return
                }
                try store.check(token)
                store.status = "Finishing and checking the movie…"
                let seconds = max(0.05, min(65, Date().timeIntervalSince(session.startedAt)))
                let source = try await session.writer.finish(duration: seconds)
                let details = try await ScreenCaptureFiles.movieDetails(source)
                try store.check(token)
                _ = try await store.publishCapture(source, token: token, kind: session.kind,
                    width: details.width, height: details.height, duration: details.duration,
                    status: "Recording saved to File Shelf. No audio was captured.")
            } catch {
                try? await session.stream.stopCapture(); await session.writer.cancel()
                if store.generation == token {
                    if error is CancellationError { store.status = "Recording cancelled; incomplete output was discarded." }
                    else { store.error = error.localizedDescription; store.status = "Recording did not publish a file." }
                }
            }
        }
    }
    func cancel() {
        preparingRecording = false
        selector.cancel(); deadline?.cancel(); deadline = nil; task?.cancel()
        intentTask?.cancel(); intentTask = nil
        if active != nil { stopRecording(discard: true) }
        else { generation = nil; isWorking = false; status = "Capture stopped; no partial capture will be published." }
    }

    private func publishCapture(_ source: URL, token: UUID, kind: CaptureSelectionKind,
                                width: Int, height: Int, duration: Double? = nil,
                                status message: String) async throws -> FileShelfItem {
        try check(token)
        let bytes = try ScreenCaptureFiles.byteCount(source)
        let item = try await shelf.addManagedCapture(source, isCurrent: { [self] in generation == token },
            didPublish: { [self] item in
                // This runs with the shelf publication, before either actor can
                // process a cancellation or let a user edit the new shelf entry.
                guard let saved = item.managedURL else { return }
                remember(CaptureShelfRecord(fileURL: saved, selection: kind, width: width,
                    height: height, duration: duration, byteCount: bytes))
                status = message; progress = 1
            })
        try check(token)
        return item
    }

    private var shelf: FileShelfToolStore { suppliedShelf ?? .shared }
    private func remember(_ record: CaptureShelfRecord) {
        let proposed = CaptureShelfArchive(records: [record] + Array(history.prefix(49)))
        do {
            _ = try proposed.validated()
            if persistState { try LocalToolStorage.save(proposed, file: "capture-shelf.json") }
            history = proposed.records
        } catch { self.error = "Capture is safe on File Shelf, but its capture-history entry could not be saved: \(error.localizedDescription)" }
    }
    func reveal(_ record: CaptureShelfRecord) {
        guard FileManager.default.fileExists(atPath: record.fileURL.path) else { error = "This shelf copy expired or was removed."; return }
        NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
    }
    func clearHistory() {
        do {
            if persistState { try LocalToolStorage.save(CaptureShelfArchive(), file: "capture-shelf.json") }
            history = []; status = "Capture history cleared; File Shelf copies were retained."
        } catch { self.error = error.localizedDescription }
    }
    func sendScreenshotToWorkflow() {
        guard let latest = history.first, latest.duration == nil,
              FileManager.default.fileExists(atPath: latest.fileURL.path),
              let preset = WorkflowStore.shared.selectedPreset, !preset.isVideoWorkflow else {
            error = "Choose a saved image workflow and an available screenshot first."; return
        }
        startWorkflow(latest.fileURL, preset: preset)
    }
    func sendRecordingToWorkflow() {
        guard let latest = history.first, latest.duration != nil,
              FileManager.default.fileExists(atPath: latest.fileURL.path),
              let preset = WorkflowStore.shared.selectedPreset, preset.isVideoWorkflow else {
            error = "Choose a saved video compression workflow and an available recording first."; return
        }
        startWorkflow(latest.fileURL, preset: preset)
    }
    /// This explicit button saves/selects a genuine video workflow when necessary.
    /// Its native runner keeps the original and publishes only a smaller output.
    func compressLatestRecording() {
        guard !isWorking, !isRecording, !WorkflowStore.shared.isRunning,
              let latest = history.first, latest.duration != nil,
              FileManager.default.fileExists(atPath: latest.fileURL.path) else {
            error = "Finish the active capture/workflow and choose an available recording first."; return
        }
        let workflows = WorkflowStore.shared
        let preset: WorkflowPreset
        if let existing = workflows.presets.first(where: { $0.isVideoWorkflow && $0.steps == [.compressVideo] }) {
            preset = existing
        } else {
            preset = .videoStarter
            guard workflows.save(preset) else { error = workflows.error ?? "Could not save the video workflow."; return }
        }
        startWorkflow(latest.fileURL, preset: preset)
    }
    private func startWorkflow(_ url: URL, preset: WorkflowPreset) {
        if WorkflowStore.shared.runExplicitly([url], presetID: preset.id) {
            error = nil; status = "Started \(preset.name). View its progress and outputs in Workflows; the capture was kept."
        } else { error = WorkflowStore.shared.error ?? "The workflow is busy or unavailable." }
    }

    private func makePlan(kind: CaptureSelectionKind, recording: Bool, token: UUID) async throws -> CapturePlan {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try check(token)
        windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width >= 8 && $0.frame.height >= 8 }
            .map { .init(id: $0.windowID, name: ($0.owningApplication?.applicationName ?? "Window") + " · " + ($0.title ?? "Untitled")) }
        let filter: SCContentFilter
        let area: CaptureArea?
        if kind == .window {
            guard let windowID, let window = content.windows.first(where: { $0.windowID == windowID }),
                  windows.contains(where: { $0.id == windowID }) else { throw ScreenCaptureFailure.noWindow }
            filter = SCContentFilter(desktopIndependentWindow: window); area = nil
        } else {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw ScreenCaptureFailure.unavailable }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            if kind == .area {
                guard let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }), let selected = await selector.choose(on: screen) else { throw CancellationError() }
                area = selected; try check(token)
            } else { area = nil }
        }
        let rectangle = area.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? filter.contentRect
        let size = try CaptureGeometry.pixels(width: rectangle.width, height: rectangle.height,
                                              scale: Double(filter.pointPixelScale), recording: recording)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width; configuration.height = size.height
        configuration.showsCursor = showsCursor; configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA; configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        if let area { configuration.sourceRect = CGRect(x: area.x, y: area.y, width: area.width, height: area.height) }
        return CapturePlan(filter: filter, configuration: configuration)
    }
}

@MainActor
private struct CapturePlan { let filter: SCContentFilter; let configuration: SCStreamConfiguration }
@MainActor
private struct CaptureSession {
    let stream: SCStream
    let writer: CaptureMovieWriter
    let directory: URL
    let kind: CaptureSelectionKind
    let startedAt: Date
    let token: UUID
}
private final class CaptureOwnedImage: @unchecked Sendable {
    let value: CGImage
    init(_ value: CGImage) { self.value = value }
}

enum ScreenCaptureFiles {
    static func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-Capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    static func byteCount(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize, count > 0 else { throw ScreenCaptureFailure.emptyMovie }
        return Int64(count)
    }
    static func writePNG(_ image: CGImage, at url: URL) throws {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, Int64(image.width) * Int64(image.height) <= 32_000_000,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ScreenCaptureFailure.unavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let decoder = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(decoder, 0, nil),
              decoded.width == image.width, decoded.height == image.height else { throw ScreenCaptureFailure.encoding("PNG verification failed.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Task.checkCancellation()
    }
    static func movieDetails(_ url: URL) async throws -> (width: Int, height: Int, duration: Double) {
        _ = try byteCount(url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 65,
              let track = tracks.first else { throw ScreenCaptureFailure.emptyMovie }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0, size.width <= 3_840, size.height <= 2_160 else { throw ScreenCaptureFailure.emptyMovie }
        try Task.checkCancellation()
        // This async nonisolated function runs away from the UI actor. Validate an actual decoded frame.
        let generator = AVAssetImageGenerator(asset: asset)
        let decoded = try generator.copyCGImage(at: .zero, actualTime: nil)
        guard decoded.width == Int(size.width), decoded.height == Int(size.height) else { throw ScreenCaptureFailure.emptyMovie }
        return (Int(size.width), Int(size.height), duration.seconds)
    }
}
